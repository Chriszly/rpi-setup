#!/usr/bin/env bash
# Task: network - give the Pi a fixed LAN address with NetworkManager.
# Settings: NETWORK_* in config/rpi-setup.env (names in config/tasks/network.env).
#
# Raspberry Pi OS Bookworm and Trixie manage the network with NetworkManager,
# so the address is set with nmcli on the connection that is active on the
# interface. Pi-hole, and anything people bookmark, needs the address of the
# Pi to stay the same.
set -euo pipefail

TASKS+=("network|Fixed LAN address (static IPv4 via NetworkManager)")

run_network() {
  local cidr="${NETWORK_STATIC_IP:-}" iface="${NETWORK_INTERFACE:-}"
  local gw="${NETWORK_GATEWAY:-}" dns="${NETWORK_DNS:-}" con current
  local -a args=()

  # Validate every setting before looking at, or changing, anything.
  if [[ -n "$iface" ]] && ! network_valid_iface "$iface"; then
    die "NETWORK_INTERFACE must be an interface name such as eth0 or wlan0 (got '$iface')"
  fi
  if [[ -n "$cidr" ]] && ! network_valid_host_cidr "$cidr"; then
    die "NETWORK_STATIC_IP must be an IPv4 host address with a prefix from 8 to 30, e.g. 192.168.1.10/24 (got '$cidr')"
  fi
  if [[ -n "$gw" ]] && ! valid_ipv4 "$gw"; then
    die "NETWORK_GATEWAY must be an IPv4 address such as 192.168.1.1 (got '$gw')"
  fi
  if [[ -n "$dns" ]]; then
    dns="$(network_dns_list "$dns")" ||
      die "NETWORK_DNS must be IPv4 addresses separated by commas, e.g. 192.168.1.1 or 1.1.1.1,9.9.9.9 (got '$NETWORK_DNS')"
  fi

  [[ -n "$iface" ]] || iface="$(default_iface)" || iface=''

  if [[ -z "$cidr" ]]; then
    network_show_dhcp "$iface"
    return 0
  fi

  if [[ -z "$gw" && -n "$iface" ]]; then gw="$(network_current_gateway "$iface")" || gw=''; fi
  if [[ -n "$gw" ]] && ! network_in_subnet "$cidr" "$gw"; then
    die "The gateway $gw is not inside NETWORK_STATIC_IP $cidr; fix NETWORK_STATIC_IP or set NETWORK_GATEWAY"
  fi
  [[ -n "$dns" || -z "$gw" ]] || dns="$gw"
  if [[ ",$dns," == *,127.0.0.1,* ]] && ! command -v pihole >/dev/null 2>&1; then
    warn 'NETWORK_DNS uses 127.0.0.1 but Pi-hole is not installed; the Pi will not resolve names until it is.'
  fi

  if in_container; then
    info 'Container/CI environment: networking is left alone. On a Pi this task would run:'
    network_nmcli_args args '<connection>' "$cidr" "${gw:-<gateway>}" "${dns:-<gateway>}"
    info "  nmcli ${args[*]}"
    info "  nmcli connection up <connection of ${iface:-<interface>}>"
    return 0
  fi

  [[ -n "$iface" ]] || die 'No default route found. Set NETWORK_INTERFACE (e.g. eth0 or wlan0) in config/rpi-setup.env.'
  [[ -e "/sys/class/net/$iface" ]] || die "There is no network interface '$iface' (list them with: ip -br link)"
  [[ -n "$gw" ]] || die "Could not find the default gateway on $iface. Set NETWORK_GATEWAY (your router, e.g. 192.168.1.1)."
  network_require_nm
  con="$(network_connection "$iface")" ||
    die "No active NetworkManager connection on $iface. Check with: nmcli device status"

  if network_is_set "$con" "$cidr" "$gw" "$dns" && network_has_addr "$iface" "$cidr"; then
    say "$iface already uses the fixed address $cidr (gateway $gw, DNS $dns)"
    return 0
  fi

  network_nmcli_args args "$con" "$cidr" "$gw" "$dns"
  info "Setting $iface to $cidr (gateway $gw, DNS $dns)"
  nmcli "${args[@]}" || die "nmcli could not change connection $con; nothing was applied."

  current="$(network_current_cidr "$iface")" || current=''
  if [[ -n "${SSH_CONNECTION:-}" && "${current%/*}" != "${cidr%/*}" ]]; then
    hr
    warn "You are connected over SSH to ${current%/*}. Applying the new address ends this session."
    warn "Reconnect with: ssh $(real_user)@${cidr%/*}"
    warn 'Tasks listed after network in this run will not run; start them again after reconnecting.'
    hr
  fi
  if command -v pihole >/dev/null 2>&1; then
    info "Pi-hole: point your router's DNS setting at ${cidr%/*}."
  fi
  info "To go back to DHCP later: sudo nmcli connection modify $con ipv4.method auto ipv4.addresses '' ipv4.gateway '' ipv4.dns '' && sudo nmcli connection up $con"
  info "Applying: the Pi is now reachable at ${cidr%/*}"
  # Applied last: over SSH to the old address, the session drops here.
  nmcli connection up "$con" >/dev/null ||
    die "nmcli could not activate the new settings on $iface; check with: nmcli device status"
  say "$iface now uses the fixed address $cidr"
}

# Print IPv4 address $1 as a 32-bit number.
network_ip_to_int() {
  local a b c d
  IFS=. read -r a b c d <<<"$1"
  printf '%d\n' $(( (a << 24) | (b << 16) | (c << 8) | d ))
}

# True if $1 is a usable LAN host address with prefix, e.g. 192.168.1.10/24:
# prefix 8-30, unicast (not 0.x, 127.x or 224.x and above), and neither the
# network nor the broadcast address of its subnet.
network_valid_host_cidr() {
  local ip="${1%/*}" prefix="${1##*/}" n host_mask first
  [[ "$1" == */* ]] || return 1
  valid_ipv4 "$ip" || return 1
  [[ "$prefix" =~ ^[0-9]{1,2}$ && "$prefix" != 0? ]] || return 1
  (( prefix >= 8 && prefix <= 30 )) || return 1
  first="${ip%%.*}"
  (( first >= 1 && first <= 223 && first != 127 )) || return 1
  n="$(network_ip_to_int "$ip")"
  host_mask=$(( (1 << (32 - prefix)) - 1 ))
  (( (n & host_mask) != 0 && (n & host_mask) != host_mask ))
}

# True if IPv4 address $2 lies inside the subnet of host address $1 (ip/prefix).
network_in_subnet() {
  local prefix="${1##*/}" a b mask
  a="$(network_ip_to_int "${1%/*}")" b="$(network_ip_to_int "$2")"
  mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
  (( (a & mask) == (b & mask) && a != b ))
}

# True if $1 looks like a Linux interface name (at most 15 characters).
network_valid_iface() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,14}$ ]]; }

# Print the DNS servers in $1 (separated by commas and/or spaces) as
# "a,b,c", or fail if one is not an IPv4 address.
network_dns_list() {
  local -a list=() out=()
  local s
  read -r -a list <<<"${1//,/ }"
  [[ ${#list[@]} -gt 0 ]] || return 1
  for s in "${list[@]}"; do
    valid_ipv4 "$s" || return 1
    out+=("$s")
  done
  (IFS=,; printf '%s\n' "${out[*]}")
}

# Fill array $1 with the nmcli arguments that set connection $2 to the fixed
# address $3 with gateway $4 and DNS servers $5 (comma separated).
network_nmcli_args() {
  local -n _net_args="$1"
  _net_args=(connection modify "$2" ipv4.method manual ipv4.addresses "$3" ipv4.gateway "$4" ipv4.dns "$5")
}

# True if connection $1 is already set to address $2, gateway $3 and DNS $4.
network_is_set() {
  local con="$1" cidr="$2" gw="$3" dns="$4" out method='' addrs='' cur_gw='' cur_dns=''
  out="$(nmcli -g ipv4.method,ipv4.addresses,ipv4.gateway,ipv4.dns connection show "$con" 2>/dev/null)" || return 1
  { read -r method || true; read -r addrs || true; read -r cur_gw || true; read -r cur_dns || true; } <<<"$out"
  addrs="${addrs// /}" cur_dns="${cur_dns// /}"
  [[ "$cur_gw" != -- ]] || cur_gw=''
  [[ "$method" == manual && "$addrs" == "$cidr" && "$cur_gw" == "$gw" && "$cur_dns" == "$dns" ]]
}

# True if interface $1 currently carries address $2 (ip/prefix).
network_has_addr() {
  ip -4 -o addr show dev "$1" 2>/dev/null | awk '{print $4}' | grep -qxF "$2"
}

# The first IPv4 address (ip/prefix) of interface $1, or non-zero exit.
network_current_cidr() {
  local c
  c="$(ip -4 -o addr show dev "$1" scope global 2>/dev/null | awk '{print $4; exit}')"
  [[ -n "$c" ]] || return 1
  printf '%s\n' "$c"
}

# The default gateway on interface $1, or non-zero exit.
network_current_gateway() {
  local g
  g="$(ip -4 route show default dev "$1" 2>/dev/null | awk '
    { for (i = 1; i <= NF; i++) if ($i == "via") { print $(i + 1); exit } }')"
  [[ -n "$g" ]] || return 1
  printf '%s\n' "$g"
}

# UUID of the NetworkManager connection active on interface $1, or non-zero exit.
network_connection() {
  local u
  u="$(nmcli -t -f DEVICE,UUID connection show --active 2>/dev/null | awk -F: -v d="$1" '$1 == d { print $2; exit }')"
  [[ -n "$u" ]] || return 1
  printf '%s\n' "$u"
}

# Die unless NetworkManager is installed and running.
network_require_nm() {
  command -v nmcli >/dev/null 2>&1 ||
    die 'nmcli was not found. This task needs NetworkManager (the default on Raspberry Pi OS Bookworm and Trixie).'
  [[ "$(nmcli -t -f RUNNING general 2>/dev/null)" == running ]] ||
    die 'NetworkManager is not running. Start it with: sudo systemctl enable --now NetworkManager (or reserve the address in your router instead).'
}

# NETWORK_STATIC_IP is empty: keep DHCP and show how to make the address stick.
network_show_dhcp() {
  local iface="$1" cur mac=''
  if [[ -z "$iface" ]]; then
    warn 'NETWORK_STATIC_IP is empty and there is no default route, so there is no LAN address to show.'
    return 0
  fi
  cur="$(network_current_cidr "$iface")" || cur=''
  [[ -r "/sys/class/net/$iface/address" ]] && mac="$(<"/sys/class/net/$iface/address")"
  info "NETWORK_STATIC_IP is empty: $iface keeps its address from DHCP (${cur:-none yet})."
  info "To keep it fixed, reserve ${cur:+${cur%/*} }for MAC ${mac:-of $iface} in your router's DHCP settings,"
  info "or set NETWORK_STATIC_IP=${cur:-192.168.1.10/24} in config/rpi-setup.env and run: sudo bash setup.sh network"
}
