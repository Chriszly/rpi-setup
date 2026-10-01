#!/usr/bin/env bash
set -euo pipefail

# Shared provisioning and verification logic for CI.
# Used by the provision-gate (nspawn), provision-qemu (QEMU) and docker-smoke
# (plain runner) jobs. All three run the same sequence:
#   provision -> verify services -> verify containers -> verify endpoints
#   -> idempotency re-run
#
# Usage: PROVISION_PROFILE=<profile> bash ci/provision.sh [WORKDIR]
#
# The profile (the case block below) selects the task list and what gets
# verified. On failure the EXIT trap collects the journal, service status and
# container logs into $WORKDIR/ci-logs so the workflow can upload them.

. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"  # in_container

PROFILE="${PROVISION_PROFILE:-}"

# Endpoints are "url:retries" (5 s apart). LANIP is replaced with
# the machine's first LAN address, so a service that only listens on
# localhost fails the check the way it would fail for a user on another PC.
case "$PROFILE" in
    # The nspawn gate (no Docker) in two halves that run as parallel jobs:
    # package installs under arm64 emulation dominate it.
    container-system)
        TASKS=(base samba)
        SERVICES=(smbd fail2ban)
        ENABLED=(ssh)
        CONTAINERS=()
        ENDPOINTS=()
        ;;
    container-web)
        TASKS=(web monitoring pihole)
        SERVICES=(nginx netdata)
        ENABLED=()
        CONTAINERS=()
        ENDPOINTS=("http://LANIP:19999:60" "http://LANIP:80:12")
        ;;
    # Every task except tailscale (QEMU VM).
    full)
        TASKS=(base docker samba web monitoring pihole netalertx teamspeak)
        SERVICES=(docker smbd nginx netdata fail2ban)
        ENABLED=(ssh)
        CONTAINERS=(netalertx teamspeak)
        ENDPOINTS=("http://LANIP:19999:60" "http://LANIP:80:12" "http://LANIP:20211:120")
        ;;
    # Only the Docker-based tasks (plain runner).
    docker)
        TASKS=(docker netalertx teamspeak)
        SERVICES=(docker)
        ENABLED=()
        CONTAINERS=(netalertx teamspeak)
        ENDPOINTS=("http://LANIP:20211:120")
        ;;
    *)
        echo "Unknown PROVISION_PROFILE '$PROFILE' (expected container-system, container-web, full or docker)" >&2
        exit 2
        ;;
esac

LOG_DIR=""

collect_logs() {
    local rc=$?
    [[ $rc -ne 0 ]] || return 0
    [[ -n "$LOG_DIR" ]] || return 0
    echo "=== Provisioning failed (exit $rc); collecting logs into $LOG_DIR ===" >&2
    mkdir -p "$LOG_DIR" || return 0
    {
        echo "profile=$PROFILE"
        echo "exit=$rc"
        echo "tasks=${TASKS[*]}"
    } >"$LOG_DIR/summary.txt" 2>&1 || true
    journalctl -b --no-pager >"$LOG_DIR/journal.txt" 2>&1 || true
    dmesg >"$LOG_DIR/dmesg.txt" 2>&1 || true
    cp /var/log/*.log "$LOG_DIR/" 2>/dev/null || true
    for svc in "${SERVICES[@]}"; do
        systemctl status "$svc" --no-pager -l >"$LOG_DIR/systemctl-$svc.txt" 2>&1 || true
    done
    if command -v docker >/dev/null 2>&1; then
        docker ps -a >"$LOG_DIR/docker-ps.txt" 2>&1 || true
        for c in "${CONTAINERS[@]}"; do
            docker logs "$c" >"$LOG_DIR/docker-$c.log" 2>&1 || true
        done
    fi
    chmod -R a+rX "$LOG_DIR" 2>/dev/null || true
}
trap collect_logs EXIT

# Settings go through the central file, as for a user: config/rpi-setup.env
# (here in a temp folder via RPI_SETUP_CONFIG_DIR) is split per task by
# setup.sh. The re-run uses the same file without SAMBA_PASSWORD and has no
# terminal, like a user re-running setup.sh from a script: samba must keep
# the existing password instead of prompting or generating a new one.
CI_CONFIG_DIR=""
CI_WEB_TITLE="rpi-setup CI $$"

write_ci_config() {
    local mode="$1"
    {
        echo "WEB_TITLE='$CI_WEB_TITLE'"
        echo "BASE_TIMEZONE=Europe/Berlin"
        echo "BASE_FAIL2BAN_MAXRETRY=4"
        echo "PIHOLE_CONFIRM=yes"
        echo "MONITORING_TELEMETRY=no"
        [[ "$mode" == rerun ]] || echo "SAMBA_PASSWORD=testpw"
    } >"$CI_CONFIG_DIR/rpi-setup.env"
    chmod 0600 "$CI_CONFIG_DIR/rpi-setup.env"
}

run_setup() {
    local workdir="$1" mode="${2:-}"
    cd "$workdir"
    [[ -n "$CI_CONFIG_DIR" ]] || CI_CONFIG_DIR="$(mktemp -d)"
    write_ci_config "$mode"
    RPI_SETUP_CONFIG_DIR="$CI_CONFIG_DIR" bash setup.sh "${TASKS[@]}" </dev/null
}

# The settings from the central file reached the tasks.
verify_settings() {
    echo "=== Verifying settings from config/rpi-setup.env ==="
    local t
    for t in "${TASKS[@]}"; do
        case "$t" in
            web)
                grep -qF "$CI_WEB_TITLE" /var/www/html/index.html ||
                    { echo "FAILED: WEB_TITLE not on the start page" >&2; return 1; }
                echo "OK: WEB_TITLE applied" ;;
            base)
                [[ "$(readlink -f /etc/localtime)" == */Europe/Berlin ]] ||
                    { echo "FAILED: BASE_TIMEZONE not applied ($(readlink -f /etc/localtime))" >&2; return 1; }
                grep -qx 'maxretry = 4' /etc/fail2ban/jail.local ||
                    { echo "FAILED: BASE_FAIL2BAN_MAXRETRY not applied" >&2; return 1; }
                echo "OK: BASE_TIMEZONE and BASE_FAIL2BAN_MAXRETRY applied" ;;
            samba)
                [[ -n "$(pdbedit -L 2>/dev/null)" ]] ||
                    { echo "FAILED: no Samba user was created" >&2; return 1; }
                echo "OK: Samba user exists" ;;
        esac
    done
}

# ENABLED units are only checked for "enabled", not "running": in the nspawn
# gate the guest shares the runner's network, where port 22 is already taken.
verify_services() {
    echo "=== Verifying services ==="
    local svc state
    for svc in "${SERVICES[@]}"; do
        systemctl is-active "$svc"
    done
    for svc in "${ENABLED[@]}"; do
        if ! state="$(systemctl is-enabled "$svc" 2>&1)"; then
            echo "FAILED: $svc is not enabled ($state)" >&2
            return 1
        fi
        echo "OK: $svc is $state"
    done
}

verify_containers() {
    if [[ ${#CONTAINERS[@]} -eq 0 ]]; then
        echo "=== No containers to verify for profile '$PROFILE' ==="
        return
    fi
    echo "=== Verifying containers ==="
    docker ps
    local c
    for c in "${CONTAINERS[@]}"; do
        if [[ -z "$(docker ps -q --filter "name=^${c}\$" --filter status=running)" ]]; then
            echo "FAILED: container '$c' is not running" >&2
            return 1
        fi
        echo "OK: container '$c' is running"
    done
}

# wait_url URL RETRIES
wait_url() {
    if curl -fsS -o /dev/null --retry "$2" --retry-delay 5 --retry-all-errors "$1"; then
        echo "OK: $1"
    else
        echo "FAILED: $1 not reachable after $2 retries" >&2
        return 1
    fi
}

verify_endpoints() {
    echo "=== Verifying web endpoints ==="
    local endpoint url retries lanip
    lanip="$(hostname -I | awk '{print $1}')"
    [[ -n "$lanip" ]] || { echo "FAILED: no LAN address found (hostname -I)" >&2; return 1; }
    for endpoint in "${ENDPOINTS[@]}"; do
        url="${endpoint%:*}"
        url="${url/LANIP/$lanip}"
        retries="${endpoint##*:}"
        wait_url "$url" "$retries"
    done
}

# The nspawn gate (x86 runner, arm64 guest under qemu-user) cannot set up the
# mount namespaces that systemd sandboxing options need: units using them die
# with "Failed at step NAMESPACE" (systemd-logind does too). Netdata's own
# package, which "monitoring" installs on Trixie, is sandboxed that way, so in
# containers only, replace its unit with a copy minus the sandboxing lines.
# Real Pis and the QEMU VM keep the unit as shipped.
unsandbox_in_container() {
    in_container || return 0
    local unit=netdata.service frag
    frag="$(systemctl show -P FragmentPath "$unit" 2>/dev/null)" || return 0
    [[ -n "$frag" && -f "$frag" && "$frag" != /etc/* ]] || return 0
    grep -Ev '^[[:space:]]*(Protect[A-Za-z]*|Private[A-Za-z]*|ProcSubset|LogNamespace|ReadWritePaths|ReadOnlyPaths|InaccessiblePaths|ReadWriteDirectories|ReadOnlyDirectories|InaccessibleDirectories|ExecPaths|NoExecPaths|BindPaths|BindReadOnlyPaths|TemporaryFileSystem|MountAPIVFS|RestrictFileSystems)=' \
        "$frag" >"/etc/systemd/system/$unit"
    echo "=== CI: using an unsandboxed copy of $frag ==="
    systemctl daemon-reload
    systemctl restart "$unit" || true
}

# Every package install ends in "systemctl daemon-reload", and on Trixie in the
# nspawn gate each reload took ~16 s (36 reloads, ~9.5 of the ~16 min of the
# "system" half). Nearly all of it is rpi-swap-generator, which takes ~11 s
# under qemu-user; the rest is other generators and units that can never start
# in this container (getty: CREDENTIALS, logind: NAMESPACE, remount-fs and the
# zram/swap units: no block devices) and restart for the whole run. In
# containers only, mask those generators and units. Real Pis and the QEMU VM
# are untouched.
CONTAINER_MASK_UNITS=(
    console-getty.service
    systemd-logind.service
    systemd-remount-fs.service
    systemd-zram-setup@zram0.service
    dev-zram0.swap
    rpi-resize-swap-file.service
    rpi-setup-loop@var-swap.service
)
CONTAINER_MASK_GENERATORS=(rpi-swap-generator zram-generator cloud-init-generator)

quiet_container_systemd() {
    in_container || return 0
    local name
    echo "=== CI: masking units and generators that cannot work in this container ==="
    mkdir -p /etc/systemd/system-generators
    for name in "${CONTAINER_MASK_GENERATORS[@]}"; do
        ln -sfn /dev/null "/etc/systemd/system-generators/$name"
    done
    # Plain symlinks instead of "systemctl mask", which reloads once per unit.
    for name in "${CONTAINER_MASK_UNITS[@]}"; do
        ln -sfn /dev/null "/etc/systemd/system/$name"
    done
    systemctl daemon-reload
    systemctl stop "${CONTAINER_MASK_UNITS[@]}" >/dev/null 2>&1 || true
    systemctl reset-failed || true
}

main() {
    local workdir="${1:-/workspace}"
    LOG_DIR="$workdir/ci-logs"

    echo "=== Profile: $PROFILE ==="
    echo "=== Tasks: ${TASKS[*]} ==="
    quiet_container_systemd

    echo "=== Provisioning ==="
    run_setup "$workdir"
    unsandbox_in_container
    verify_services
    verify_containers
    verify_endpoints
    verify_settings

    echo "=== Idempotency re-run ==="
    run_setup "$workdir" rerun
    verify_services
    verify_endpoints
    verify_settings

    echo "=== All checks passed ==="
}

main "$@"
