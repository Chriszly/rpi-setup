#!/usr/bin/env bash
# test-task-firewall.sh - unit tests for tasks/firewall.sh: input validation,
# nftables ruleset generation and service port detection (with stubs).
#
# Run: bash ci/test-task-firewall.sh   (sudo for the "nft -c" and run_firewall cases)
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"
. "$ROOT/lib/common.sh"
declare -a TASKS=()
. "$ROOT/tasks/firewall.sh"

# --- firewall_port_specs --------------------------------------------------------
assert_eq "port specs: empty" "" "$(firewall_port_specs X '')"
assert_eq "port specs: spaces and commas" "8123/tcp 1900/udp 60000-61000/udp" \
  "$(firewall_port_specs X '8123/tcp, 1900/udp,60000-61000/udp')"
assert_eq "port specs: leading zeros normalized" "80/tcp" "$(firewall_port_specs X '080/tcp')"
assert_eq "port specs: one-port range collapses" "53/udp" "$(firewall_port_specs X '53-53/udp')"
assert_fails "port specs: no protocol"        firewall_port_specs X '8123'
assert_fails "port specs: unknown protocol"   firewall_port_specs X '8123/sctp'
assert_fails "port specs: port 0"             firewall_port_specs X '0/tcp'
assert_fails "port specs: port 65536"         firewall_port_specs X '65536/tcp'
assert_fails "port specs: reversed range"     firewall_port_specs X '200-100/tcp'
assert_fails "port specs: injection attempt"  firewall_port_specs X '22/tcp;flush'
assert_contains "port specs: error names the setting" "FIREWALL_EXTRA_PORTS" \
  "$( (firewall_port_specs FIREWALL_EXTRA_PORTS 'x/tcp') 2>&1 || true)"

# --- firewall_cidrs ---------------------------------------------------------------
assert_eq "cidrs: empty" "" "$(firewall_cidrs X '')"
assert_eq "cidrs: v4 and v6" "192.168.1.0/24 10.0.0.5 fd00::/8" \
  "$(firewall_cidrs X '192.168.1.0/24, 10.0.0.5 fd00::/8')"
assert_fails "cidrs: octet over 255"    firewall_cidrs X '192.168.1.256/24'
assert_fails "cidrs: v4 prefix 33"      firewall_cidrs X '10.0.0.0/33'
assert_fails "cidrs: v6 prefix 129"     firewall_cidrs X 'fd00::/129'
assert_fails "cidrs: host name"         firewall_cidrs X 'mypc.local'
assert_fails "cidrs: injection attempt" firewall_cidrs X '10.0.0.0/8}'

# --- firewall_ports_of ------------------------------------------------------------
assert_eq "ports_of: tcp, deduplicated" "22, 80, 1000-2000" \
  "$(firewall_ports_of tcp '22/tcp 80/tcp 53/udp 80/tcp 1000-2000/tcp')"
assert_eq "ports_of: udp" "53" "$(firewall_ports_of udp '22/tcp 53/udp')"
assert_eq "ports_of: none" "" "$(firewall_ports_of udp '22/tcp')"

# --- firewall_ruleset -------------------------------------------------------------
rs="$(firewall_ruleset "22" "53/tcp 53/udp 445/tcp" "80/tcp 19999/tcp" "")"
assert_contains "ruleset: own table only" "delete table inet rpi_setup" "$rs"
assert_contains "ruleset: drop policy" "policy drop;" "$rs"
assert_contains "ruleset: established" "ct state established,related accept" "$rs"
assert_contains "ruleset: tailscale0" 'iifname "tailscale0" accept' "$rs"
assert_contains "ruleset: ssh" 'tcp dport { 22 } accept comment "SSH"' "$rs"
assert_contains "ruleset: no allow-from opens web ports to all" "tcp dport { 53, 445, 80, 19999 } accept" "$rs"
assert_contains "ruleset: udp" "udp dport { 53 } accept" "$rs"
assert_lacks "ruleset: no saddr rule without allow-from" "saddr" "$rs"
assert_lacks "ruleset: never flushes other tables" "flush ruleset" "$rs"

rs="$(firewall_ruleset "22 2222" "53/udp 80/tcp" "80/tcp 19999/tcp" "192.168.1.0/24 fd00::/8")"
assert_contains "ruleset: several ssh ports" 'tcp dport { 22, 2222 } accept comment "SSH"' "$rs"
assert_contains "ruleset: open tcp" "tcp dport { 80 } accept" "$rs"
assert_contains "ruleset: v4 web rule" 'ip saddr { 192.168.1.0/24 } tcp dport { 19999 } accept' "$rs"
assert_contains "ruleset: v6 web rule" 'ip6 saddr { fd00::/8 } tcp dport { 19999 } accept' "$rs"

rs="$(firewall_ruleset "22" "" "" "")"
assert_lacks "ruleset: no empty sets" "{ }" "$rs"
assert_lacks "ruleset: no empty sets (two spaces)" "{  }" "$rs"
assert_eq "ruleset: braces balance" "$(grep -o '{' <<<"$rs" | wc -l)" "$(grep -o '}' <<<"$rs" | wc -l)"

# --- firewall_service_ports (stubbed system) --------------------------------------
FAKE_PKGS=""
apt_installed() { [[ " $FAKE_PKGS " == *" $1 "* ]]; }
FAKE_FTL_PORT="80o,443os,[::]:80o,[::]:443os" FAKE_DHCP=false
pihole-FTL() {
  case "$2" in
    webserver.port) printf '%s\n' "$FAKE_FTL_PORT" ;;
    dhcp.active) printf '%s\n' "$FAKE_DHCP" ;;
    dhcp.ipv6) printf 'false\n' ;;
  esac
}
export RPI_SETUP_CONFIG_DIR="$TMP/cfg"
mkdir -p "$RPI_SETUP_CONFIG_DIR/local"

if [[ -e /opt/netalertx/docker-compose.yml || -e /opt/teamspeak/docker-compose.yml ]] ||
   command -v tailscale >/dev/null 2>&1; then
  skip "firewall_service_ports: this machine has NetAlertX, TeamSpeak or Tailscale installed"
else
  out="$(firewall_service_ports)"
  assert_contains "services: pihole dns udp" "53/udp open pihole-dns" "$out"
  assert_contains "services: pihole web 80" "80/tcp web pihole-web" "$out"
  assert_contains "services: pihole web 443" "443/tcp web pihole-web" "$out"
  assert_lacks "services: no DHCP when off" "67/udp" "$out"

  FAKE_DHCP=true
  assert_contains "services: pihole DHCP" "67/udp open pihole-dhcp" "$(firewall_service_ports)"

  FAKE_FTL_PORT="" FAKE_DHCP=false
  printf "PIHOLE_WEB_PORT='8081'\n" >"$RPI_SETUP_CONFIG_DIR/local/pihole.env"
  assert_contains "services: pihole web port from settings" "8081/tcp web pihole-web" "$(firewall_service_ports)"

  unset -f pihole-FTL
  FAKE_PKGS="samba"
  out="$(firewall_service_ports)"
  assert_contains "services: samba 445" "445/tcp open samba" "$out"
  assert_lacks "services: no pihole when absent" "pihole" "$out"

  # Tasks in their containers (<TASK>_DOCKER=yes): nothing installed natively.
  ctr="$TMP/opt"
  for t in web pihole samba; do install -d "$ctr/$t"; touch "$ctr/$t/docker-compose.yml"; done
  install -d "$ctr/web/conf"
  printf 'server {\n    listen 8090;\n    listen [::]:8090;\n}\n' >"$ctr/web/conf/default.conf"
  FAKE_PKGS=""
  docker() {
    case "$1 ${2:-}" in
      "inspect --type") [[ " web pihole samba " == *" ${4:-} "* ]] ;;
      "exec pihole")
        case "$5" in webserver.port) echo '8091o,[::]:8091o' ;; dhcp.active) echo true ;; dhcp.ipv6) echo false ;; esac ;;
      *) return 1 ;;
    esac
  }
  out="$(RPI_SETUP_CONTAINER_ROOT="$ctr" firewall_service_ports)"
  assert_contains "containers: pihole dns" "53/udp open pihole-dns" "$out"
  assert_contains "containers: pihole web port from FTL in the container" "8091/tcp web pihole-web" "$out"
  assert_contains "containers: pihole DHCP from the container" "67/udp open pihole-dhcp" "$out"
  assert_contains "containers: nginx port from the container's site" "8090/tcp web nginx" "$out"
  assert_contains "containers: samba" "445/tcp open samba" "$out"
  install -d "$ctr/usagecontrol"; touch "$ctr/usagecontrol/docker-compose.yml"
  assert_contains "containers: usage-control on its default port" "8090/tcp web usagecontrol" \
    "$(RPI_SETUP_CONTAINER_ROOT="$ctr" firewall_service_ports)"
  assert_contains "containers: usage-control port from its settings" "8095/tcp web usagecontrol" \
    "$(USAGECONTROL_PORT=8095 RPI_SETUP_CONTAINER_ROOT="$ctr" firewall_service_ports)"
  unset -f docker
fi

# --- nft -c on generated rules, and run_firewall in container mode (root) ---------
if [[ $EUID -eq 0 ]] && command -v nft >/dev/null 2>&1 &&
   printf 'table inet rpi_setup_probe\ndelete table inet rpi_setup_probe\n' >"$TMP/probe.nft" &&
   nft -c -f "$TMP/probe.nft" >/dev/null 2>&1; then
  firewall_ruleset "22 2222" "53/tcp 53/udp 67/udp 8000-8100/tcp" "80/tcp 19999/tcp" \
    "192.168.1.0/24 10.0.0.1 fd00::/8" >"$TMP/full.nft"
  assert_ok "nft -c accepts the full ruleset" nft -c -f "$TMP/full.nft"
  firewall_ruleset "22" "" "" "" >"$TMP/min.nft"
  assert_ok "nft -c accepts the minimal ruleset" nft -c -f "$TMP/min.nft"

  # run_firewall with the system parts stubbed: generates, checks and writes
  # the files, then stops before loading anything (container mode).
  FAKE_PKGS=""
  env_run() { local "$1"; run_firewall; }
  in_container() { return 0; }
  systemctl() { :; }
  firewall_sshd_ports() { printf '2222 '; }
  firewall_service_ports() { printf '53/udp open pihole-dns\n80/tcp web pihole-web\n'; }
  FW_NFT_FILE="$TMP/etc/firewall.nft"
  FW_UNIT_DIR="$TMP"
  run_out="$(FIREWALL_EXTRA_PORTS='8123/tcp' FIREWALL_ALLOW_FROM='192.168.1.0/24' run_firewall 2>&1)"
  assert_contains "run_firewall: container mode does not load" "did not load" "$run_out"
  gen="$(cat "$FW_NFT_FILE")"
  assert_contains "run_firewall: sshd's real port kept" 'tcp dport { 22, 2222 }' "$gen"
  assert_contains "run_firewall: extra port" "8123" "$gen"
  assert_contains "run_firewall: web port limited" 'ip saddr { 192.168.1.0/24 } tcp dport { 80 }' "$gen"
  assert_eq "run_firewall: creates its folder root-only" "700" "$(stat -c %a "$TMP/etc")"
  assert_contains "run_firewall: unit loads the file" "ExecStart=/usr/sbin/nft -f $FW_NFT_FILE" \
    "$(cat "$TMP/rpi-setup-firewall.service")"
  before="$(stat -c %Y "$FW_NFT_FILE")"
  (FIREWALL_EXTRA_PORTS='8123/tcp' FIREWALL_ALLOW_FROM='192.168.1.0/24' run_firewall) >/dev/null 2>&1
  assert_eq "run_firewall: re-run leaves the file alone" "$before" "$(stat -c %Y "$FW_NFT_FILE")"
  assert_eq "run_firewall: re-run keeps the folder root-only" "700" "$(stat -c %a "$TMP/etc")"
  assert_fails "run_firewall: bad FIREWALL_SSH_PORT" env_run FIREWALL_SSH_PORT=0
  assert_fails "run_firewall: bad FIREWALL_EXTRA_PORTS" env_run FIREWALL_EXTRA_PORTS=http
  assert_fails "run_firewall: bad FIREWALL_ALLOW_FROM" env_run FIREWALL_ALLOW_FROM=lan
  assert_fails "run_firewall: bad FIREWALL_AUTO_PORTS" env_run FIREWALL_AUTO_PORTS=maybe
else
  skip "nft -c and run_firewall cases need root and a working nft"
fi

finish_tests
