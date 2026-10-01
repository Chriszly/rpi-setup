#!/usr/bin/env bash
# Task: tailscale - WireGuard mesh VPN via the official install script.
# Settings: TAILSCALE_* in config/rpi-setup.env (names in config/tasks/tailscale.env).
set -euo pipefail
. "$RPI_SETUP_ROOT/lib/containers.sh"

TASKS+=("tailscale|Tailscale VPN (official install script)")

run_tailscale() {
  : "${TAILSCALE_DOCKER:=no}"
  local -a opts=()
  tailscale_options opts
  if setting_on TAILSCALE_DOCKER; then run_tailscale_container "${opts[@]}"; return; fi
  container_leave tailscale

  if ! command -v tailscale >/dev/null 2>&1; then
    warn 'The Tailscale installer uses "curl ... | sh"; review https://tailscale.com/install.sh if in doubt.'
    curl -fsSL https://tailscale.com/install.sh | sh
  else
    say 'tailscale binary already present'
  fi

  systemctl enable --now tailscaled
  tailscale_forwarding

  # "tailscale status" exits non-zero until this node is logged in. (The
  # tailscale0 interface is not a signal: tailscaled creates it logged out too.)
  if tailscale status >/dev/null 2>&1; then
    say 'Tailscale is already up'
    if [[ ${#opts[@]} -gt 0 ]]; then
      info "Applying settings: ${opts[*]}"
      tailscale set "${opts[@]}" || die 'tailscale set failed; check the TAILSCALE_* settings'
    fi
  elif [[ -n "${TAILSCALE_AUTHKEY:-}" ]]; then
    info 'Logging in to Tailscale with TAILSCALE_AUTHKEY'
    tailscale up --authkey "$TAILSCALE_AUTHKEY" "${opts[@]}" || die 'tailscale up failed with the given auth key'
  else
    info 'Running "tailscale up" - open the printed URL to log this Pi in to your tailnet'
    tailscale up "${opts[@]}" || warn 'Login not completed; run "sudo tailscale up" later to finish.'
  fi
  tailscale status || true
}

# Fill array $1 with the "tailscale up/set" flags for the settings that are
# set. An empty setting adds no flag, so a re-run never undoes something
# configured by hand with "tailscale set".
tailscale_options() {
  local -n _ts_opts="$1"
  local routes="${TAILSCALE_ADVERTISE_ROUTES:-}" r
  if [[ -n "${TAILSCALE_HOSTNAME:-}" ]]; then
    valid_hostname "$TAILSCALE_HOSTNAME" || die "TAILSCALE_HOSTNAME must be letters, digits and '-' (got '$TAILSCALE_HOSTNAME')"
    _ts_opts+=("--hostname=$TAILSCALE_HOSTNAME")
  fi
  ts_bool_flag TAILSCALE_SSH --ssh
  ts_bool_flag TAILSCALE_ADVERTISE_EXIT_NODE --advertise-exit-node
  # A Pi running Pi-hole is the DNS server: taking the tailnet's DNS settings
  # (MagicDNS, or a global nameserver pointing at this Pi) would make it
  # resolve through itself. So "auto" (empty) turns it off when Pi-hole is here.
  if [[ -n "${TAILSCALE_ACCEPT_DNS:-}" ]]; then
    ts_bool_flag TAILSCALE_ACCEPT_DNS --accept-dns
  elif tailscale_pihole_here; then
    _ts_opts+=(--accept-dns=false)
  fi
  if [[ -n "$routes" ]]; then
    routes="${routes// /}"
    for r in ${routes//,/ }; do
      [[ "$r" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ || "$r" =~ ^[0-9a-fA-F:]+/[0-9]{1,3}$ ]] ||
        die "TAILSCALE_ADVERTISE_ROUTES: '$r' is not a subnet like 192.168.1.0/24"
    done
    _ts_opts+=("--advertise-routes=$routes")
  fi
}

# Add flag $2=true or $2=false to tailscale_options' array as yes/no setting
# $1 says; nothing when $1 is empty.
ts_bool_flag() {
  [[ -n "${!1:-}" ]] || return 0
  if setting_on "$1"; then _ts_opts+=("$2=true"); else _ts_opts+=("$2=false"); fi
}

# True if Pi-hole is installed on this Pi, natively or in its container.
tailscale_pihole_here() { command -v pihole >/dev/null 2>&1 || task_in_container pihole; }

# Subnet routes and exit nodes need IP forwarding.
tailscale_forwarding() {
  local f=/etc/sysctl.d/99-tailscale.conf
  if [[ -n "${TAILSCALE_ADVERTISE_ROUTES:-}" ]] ||
     { [[ -n "${TAILSCALE_ADVERTISE_EXIT_NODE:-}" ]] && setting_on TAILSCALE_ADVERTISE_EXIT_NODE; }; then
    if printf '%s\n' '# Managed by rpi-setup (tasks/tailscale.sh): routing for subnet routes / exit node.' \
        'net.ipv4.ip_forward = 1' 'net.ipv6.conf.all.forwarding = 1' | write_if_changed "$f" 0644; then
      sysctl -q -p "$f" || warn "Could not apply $f (applied on next boot)"
      say 'Enabled IP forwarding for Tailscale routing'
    fi
  fi
}


# TAILSCALE_DOCKER=yes: the official image on the host network with
# /dev/net/tun, so tailscale0, subnet routes and the exit node work as they do
# natively; state in /opt/tailscale/state. A native tailscaled is stopped and
# its state copied once, so the Pi keeps its node and needs no new login.
# Arguments: the "tailscale up/set" flags from tailscale_options.
run_tailscale_container() {
  : "${TAILSCALE_IMAGE:=tailscale/tailscale:latest}"
  require_image_ref TAILSCALE_IMAGE
  container_require_64bit TAILSCALE_DOCKER
  if [[ -n "${TAILSCALE_SSH:-}" ]] && setting_on TAILSCALE_SSH; then
    die 'Tailscale SSH from a container logs in to the container, not the Pi; set TAILSCALE_SSH=no or TAILSCALE_DOCKER=no'
  fi
  if [[ ! -c /dev/net/tun ]]; then
    modprobe tun 2>/dev/null || true
    [[ -c /dev/net/tun ]] || die 'Missing /dev/net/tun; load it with "sudo modprobe tun" and run again'
  fi
  container_require_docker
  local dir name=tailscale changed=0 url="" a
  local -a extra=()
  dir="$(container_dir tailscale)"
  # The host name goes in TS_HOSTNAME; everything else in TS_EXTRA_ARGS.
  for a in "$@"; do [[ "$a" == --hostname=* ]] || extra+=("$a"); done

  install -m 0755 -d "$dir"
  container_copy_once "$dir" /var/lib/tailscale "$dir/state" || true
  install -m 0700 -d "$dir/state"
  if [[ -n "${TAILSCALE_AUTHKEY:-}" ]]; then
    if container_write_secrets "$dir" "TS_AUTHKEY=$TAILSCALE_AUTHKEY"; then changed=1; fi
  elif [[ ! -f "$dir/secrets.env" ]]; then
    install -m 0600 /dev/null "$dir/secrets.env"
  fi
  if tailscale_container_compose "$dir" "$name" "${extra[*]}" | write_if_changed "$dir/docker-compose.yml" 0644; then changed=1; fi
  container_pull "$dir"
  tailscale_forwarding
  container_stop_native "$dir" tailscaled

  container_up "$dir" "$name" "$changed"

  if docker exec "$name" tailscale status >/dev/null 2>&1; then
    if [[ $# -gt 0 ]]; then
      info "Applying settings: $*"
      docker exec "$name" tailscale set "$@" || die 'tailscale set failed; check the TAILSCALE_* settings'
    fi
    say 'Tailscale container is up'
    docker exec "$name" tailscale status || true
    return
  fi
  url="$(wait_for_log "$name" 'https://login.tailscale.com/' 60 | grep -oE 'https://login\.tailscale\.com/[^ ]+' | tail -1)" || url=""
  if [[ -n "$url" ]]; then
    say "Open this URL to log this Pi in to your tailnet: $url"
  else
    warn "Not logged in yet; see the login URL with: docker logs $name (or set TAILSCALE_AUTHKEY)"
  fi
}

# Compose file: folder $1, container name $2, extra "tailscale up" flags $3.
tailscale_container_compose() {
  local dir="$1" name="$2" args="$3" host="${TAILSCALE_HOSTNAME:-$(hostname)}"
  cat <<EOF
services:
  tailscale:
    image: "$TAILSCALE_IMAGE"
    container_name: $name
    hostname: $host
    restart: unless-stopped
    network_mode: host
    pids_limit: 512
    cap_add:
      - NET_ADMIN
      - NET_RAW
    devices:
      - /dev/net/tun:/dev/net/tun
    env_file: ./secrets.env
    environment:
      TS_STATE_DIR: /var/lib/tailscale
      TS_USERSPACE: "false"
      TS_AUTH_ONCE: "true"
      TS_HOSTNAME: "$host"
      TS_EXTRA_ARGS: "$args"
    volumes:
      - $dir/state:/var/lib/tailscale
EOF
}
