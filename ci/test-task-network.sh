#!/usr/bin/env bash
# test-task-network.sh - unit tests for the helpers in tasks/network.sh.
#
# nmcli and ip are stubbed with shell functions, so nothing here touches the
# network of the machine running the tests.
#
# Run: bash ci/test-task-network.sh
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"
. "$ROOT/lib/common.sh"
declare -a TASKS=()
. "$ROOT/tasks/network.sh"

assert_eq "network registers its task" "network" "${TASKS[0]%%|*}"

# --- network_valid_ipv4 -------------------------------------------------------
assert_ok    "ipv4 accepts 192.168.1.1"      network_valid_ipv4 192.168.1.1
assert_ok    "ipv4 accepts 0 octets"         network_valid_ipv4 10.0.0.1
assert_ok    "ipv4 accepts 255"              network_valid_ipv4 255.255.255.255
assert_fails "ipv4 rejects 256"              network_valid_ipv4 192.168.1.256
assert_fails "ipv4 rejects leading zero"     network_valid_ipv4 192.168.01.1
assert_fails "ipv4 rejects three octets"     network_valid_ipv4 192.168.1
assert_fails "ipv4 rejects five octets"      network_valid_ipv4 1.2.3.4.5
assert_fails "ipv4 rejects a prefix"         network_valid_ipv4 192.168.1.1/24
assert_fails "ipv4 rejects letters"          network_valid_ipv4 192.168.a.1
assert_fails "ipv4 rejects empty"            network_valid_ipv4 ''
assert_fails "ipv4 rejects trailing space"   network_valid_ipv4 '1.2.3.4 '

# --- network_valid_host_cidr --------------------------------------------------
assert_ok    "cidr accepts 192.168.1.10/24"  network_valid_host_cidr 192.168.1.10/24
assert_ok    "cidr accepts 10.0.5.2/8"       network_valid_host_cidr 10.0.5.2/8
assert_ok    "cidr accepts /30 host"         network_valid_host_cidr 192.168.1.1/30
assert_fails "cidr rejects missing prefix"   network_valid_host_cidr 192.168.1.10
assert_fails "cidr rejects /32"              network_valid_host_cidr 192.168.1.10/32
assert_fails "cidr rejects /7"               network_valid_host_cidr 10.0.0.1/7
assert_fails "cidr rejects prefix 024"       network_valid_host_cidr 192.168.1.10/024
assert_fails "cidr rejects empty prefix"     network_valid_host_cidr 192.168.1.10/
assert_fails "cidr rejects network address"  network_valid_host_cidr 192.168.1.0/24
assert_fails "cidr rejects broadcast"        network_valid_host_cidr 192.168.1.255/24
assert_fails "cidr rejects loopback"         network_valid_host_cidr 127.0.0.2/8
assert_fails "cidr rejects multicast"        network_valid_host_cidr 224.0.0.5/24
assert_fails "cidr rejects 0.x"              network_valid_host_cidr 0.1.2.3/8
assert_fails "cidr rejects bad address"      network_valid_host_cidr 192.168.1.300/24

# --- network_in_subnet --------------------------------------------------------
assert_ok    "gateway in /24"                network_in_subnet 192.168.1.10/24 192.168.1.1
assert_ok    "gateway in /16"                network_in_subnet 192.168.5.10/16 192.168.0.1
assert_fails "gateway outside /24"           network_in_subnet 192.168.1.10/24 192.168.2.1
assert_fails "gateway equal to the address"  network_in_subnet 192.168.1.10/24 192.168.1.10

# --- network_valid_iface / network_dns_list -----------------------------------
assert_ok    "iface accepts eth0"            network_valid_iface eth0
assert_ok    "iface accepts end0.10"         network_valid_iface end0.10
assert_fails "iface rejects a slash"         network_valid_iface eth0/x
assert_fails "iface rejects 16 characters"   network_valid_iface abcdefghijklmnop
assert_eq    "dns single"                    "192.168.1.1" "$(network_dns_list 192.168.1.1)"
assert_eq    "dns commas and spaces"         "1.1.1.1,9.9.9.9" "$(network_dns_list '1.1.1.1, 9.9.9.9')"
assert_eq    "dns spaces only"               "1.1.1.1,9.9.9.9" "$(network_dns_list '1.1.1.1 9.9.9.9')"
assert_fails "dns rejects a name"            network_dns_list dns.google
assert_fails "dns rejects one bad entry"     network_dns_list '1.1.1.1,1.1.1'
assert_fails "dns rejects empty list"        network_dns_list ' , '

# --- network_nmcli_args -------------------------------------------------------
args=()
network_nmcli_args args my-uuid 192.168.1.10/24 192.168.1.1 1.1.1.1,9.9.9.9
assert_eq "nmcli arguments" \
    "connection|modify|my-uuid|ipv4.method|manual|ipv4.addresses|192.168.1.10/24|ipv4.gateway|192.168.1.1|ipv4.dns|1.1.1.1,9.9.9.9" \
    "$(IFS='|'; printf '%s' "${args[*]}")"

# --- stubs for nmcli and ip ----------------------------------------------------
# NMCLI_SHOW is what "nmcli -g ... connection show" prints; NMCLI_LOG records
# every other nmcli call.
NMCLI_LOG="$TMP/nmcli.log"
NMCLI_SHOW=''
NMCLI_RUNNING=running
IP_ADDR='2: lo    inet 192.168.1.10/24 brd 192.168.1.255 scope global lo'
IP_ROUTE='default via 192.168.1.1 dev lo proto dhcp src 192.168.1.10 metric 100'
nmcli() {
    case "$*" in
        '-g ipv4.method,ipv4.addresses,ipv4.gateway,ipv4.dns connection show '*) printf '%s\n' "$NMCLI_SHOW" ;;
        '-t -f RUNNING general') printf '%s\n' "$NMCLI_RUNNING" ;;
        '-t -f DEVICE,UUID connection show --active') printf 'wlan9:other-uuid\nlo:lo-uuid\n' ;;
        *) printf '%s\n' "$*" >>"$NMCLI_LOG" ;;
    esac
}
ip() {
    case "$*" in
        '-4 -o addr show dev '*) printf '%s\n' "$IP_ADDR" ;;
        '-4 route show default dev '*) printf '%s\n' "$IP_ROUTE" ;;
        'route show default') printf '%s\n' "$IP_ROUTE" ;;
        *) return 1 ;;
    esac
}
in_container() { return 1; }

# --- network_is_set -------------------------------------------------------------
NMCLI_SHOW=$'manual\n192.168.1.10/24\n192.168.1.1\n192.168.1.1'
assert_ok    "is_set when everything matches" network_is_set c 192.168.1.10/24 192.168.1.1 192.168.1.1
NMCLI_SHOW=$'manual\n192.168.1.10/24\n192.168.1.1\n1.1.1.1, 9.9.9.9'
assert_ok    "is_set ignores spaces in the DNS list" network_is_set c 192.168.1.10/24 192.168.1.1 1.1.1.1,9.9.9.9
NMCLI_SHOW=$'auto\n\n\n'
assert_fails "not set while on DHCP"          network_is_set c 192.168.1.10/24 192.168.1.1 192.168.1.1
NMCLI_SHOW=$'manual\n192.168.1.11/24\n192.168.1.1\n192.168.1.1'
assert_fails "not set with another address"   network_is_set c 192.168.1.10/24 192.168.1.1 192.168.1.1
NMCLI_SHOW=$'manual\n192.168.1.10/24\n--\n192.168.1.1'
assert_fails "not set without a gateway"      network_is_set c 192.168.1.10/24 192.168.1.1 192.168.1.1
NMCLI_SHOW=$'manual\n192.168.1.10/24\n192.168.1.1\n8.8.8.8'
assert_fails "not set with other DNS"         network_is_set c 192.168.1.10/24 192.168.1.1 192.168.1.1

# --- small lookups ------------------------------------------------------------
assert_eq "connection of lo"     "lo-uuid"         "$(network_connection lo)"
assert_fails "no connection on eth7" network_connection eth7
assert_eq "current address"      "192.168.1.10/24" "$(network_current_cidr lo)"
assert_eq "current gateway"      "192.168.1.1"     "$(network_current_gateway lo)"
assert_ok "has the address"      network_has_addr lo 192.168.1.10/24
assert_fails "lacks other address" network_has_addr lo 192.168.1.20/24

# --- run_network ------------------------------------------------------------------
# Cases use NETWORK_INTERFACE=lo (exists everywhere) unless they set one; nmcli and ip
# are the stubs above, so nothing is changed for real.
# Arguments are NAME=value pairs to export for that one run.
# shellcheck disable=SC2163
env_run() { ( unset SSH_CONNECTION; export NETWORK_INTERFACE=lo "$@"; run_network ) 2>&1; }

assert_fails "bad NETWORK_STATIC_IP stops the run" env_run NETWORK_STATIC_IP=192.168.1.10
assert_fails "bad NETWORK_GATEWAY stops the run"   env_run NETWORK_STATIC_IP=192.168.1.10/24 NETWORK_GATEWAY=192.168.1
assert_fails "bad NETWORK_DNS stops the run"       env_run NETWORK_STATIC_IP=192.168.1.10/24 NETWORK_DNS=x
assert_fails "bad NETWORK_INTERFACE stops the run" env_run NETWORK_STATIC_IP=192.168.1.10/24 NETWORK_INTERFACE='a b'
assert_fails "gateway outside the subnet stops the run" \
    env_run NETWORK_STATIC_IP=10.0.0.5/24 NETWORK_GATEWAY=192.168.1.1
assert_contains "gateway error names the gateway" "192.168.1.1 is not inside" \
    "$(env_run NETWORK_STATIC_IP=10.0.0.5/24 NETWORK_GATEWAY=192.168.1.1 || true)"

out="$(env_run NETWORK_STATIC_IP=)"
assert_contains "empty NETWORK_STATIC_IP keeps DHCP" "keeps its address from DHCP (192.168.1.10/24)" "$out"
assert_contains "empty NETWORK_STATIC_IP hints at a reservation" "reserve 192.168.1.10 for MAC" "$out"
assert_eq "empty NETWORK_STATIC_IP calls no nmcli" "" "$(cat "$NMCLI_LOG")"

out="$(in_container() { return 0; }; env_run NETWORK_STATIC_IP=192.168.1.20/24)"
assert_contains "container run only prints the plan" \
    "nmcli connection modify <connection> ipv4.method manual ipv4.addresses 192.168.1.20/24 ipv4.gateway 192.168.1.1 ipv4.dns 192.168.1.1" "$out"
assert_eq "container run changes nothing" "" "$(cat "$NMCLI_LOG")"

NMCLI_RUNNING=stopped
assert_contains "NetworkManager not running is explained" "NetworkManager is not running" \
    "$(env_run NETWORK_STATIC_IP=192.168.1.20/24 || true)"
NMCLI_RUNNING=running

# Already set: nothing is modified.
NMCLI_SHOW=$'manual\n192.168.1.10/24\n192.168.1.1\n192.168.1.1'
out="$(env_run NETWORK_STATIC_IP=192.168.1.10/24)"
assert_contains "already set is reported" "already uses the fixed address 192.168.1.10/24" "$out"
assert_eq "already set calls no nmcli modify/up" "" "$(cat "$NMCLI_LOG")"

# New address: modify, then bring the connection up (in that order).
NMCLI_SHOW=$'auto\n\n\n'
out="$(env_run NETWORK_STATIC_IP=192.168.1.20/24 NETWORK_DNS='1.1.1.1, 9.9.9.9')"
assert_eq "new address modifies then activates the connection" \
    "connection modify lo-uuid ipv4.method manual ipv4.addresses 192.168.1.20/24 ipv4.gateway 192.168.1.1 ipv4.dns 1.1.1.1,9.9.9.9
connection up lo-uuid" "$(cat "$NMCLI_LOG")"
assert_contains "new address is printed" "reachable at 192.168.1.20" "$out"
: >"$NMCLI_LOG"

# Over SSH to another address: a clear warning with the address to reconnect to.
out="$(env_run SSH_CONNECTION='192.168.1.5 5000 192.168.1.10 22' NETWORK_STATIC_IP=192.168.1.20/24)"
assert_contains "SSH users are warned" "Applying the new address ends this session" "$out"
assert_contains "SSH users get the new address" "@192.168.1.20" "$out"
: >"$NMCLI_LOG"

finish_tests
