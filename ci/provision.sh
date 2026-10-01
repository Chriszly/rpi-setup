#!/usr/bin/env bash
set -euo pipefail

# Shared provisioning and verification logic for CI.
# Used by the provision-gate (nspawn), provision-qemu (QEMU) and docker-smoke
# (plain runner) jobs. All three run the same sequence:
#   provision -> verify services -> verify containers -> verify endpoints
#   -> idempotency re-run
#
# Usage: bash ci/provision.sh [WORKDIR]
#
# The task list, and what gets verified, is selected by a profile:
#   PROVISION_PROFILE=container  tasks that work in systemd-nspawn (no Docker)
#   PROVISION_PROFILE=container-system / container-web
#                                the container profile split in two halves that
#                                the PR gate runs as parallel jobs
#   PROVISION_PROFILE=full       every task except tailscale (QEMU VM)
#   PROVISION_PROFILE=docker     only the Docker-based tasks (plain runner)
# When PROVISION_PROFILE is unset the profile is auto-detected: "container"
# inside a container, "full" otherwise.
#
# On failure the EXIT trap collects the journal, service status and container
# logs into $WORKDIR/ci-logs so the workflow can upload them as an artifact.

in_container() {
    [[ -f /run/systemd/container ]] || grep -q 'container' /proc/1/cgroup 2>/dev/null
}

PROFILE="${PROVISION_PROFILE:-}"
if [[ -z "$PROFILE" ]]; then
    if in_container; then PROFILE=container; else PROFILE=full; fi
fi

# Endpoints are "url:max_tries" (5 s between tries). LANIP is replaced with
# the machine's first LAN address, so a service that only listens on
# localhost fails the check the way it would fail for a user on another PC.
case "$PROFILE" in
    container)
        TASKS=(base samba web monitoring pihole)
        SERVICES=(smbd nginx netdata fail2ban)
        ENABLED=(ssh)
        CONTAINERS=()
        ENDPOINTS=("http://LANIP:19999:60" "http://LANIP:80:12")
        ;;
    # The two halves of "container". Package installs under arm64 emulation
    # dominate the gate, so they are split into roughly equal parts.
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
    full)
        TASKS=(base docker samba web monitoring pihole netalertx teamspeak)
        SERVICES=(docker smbd nginx netdata fail2ban)
        ENABLED=(ssh)
        CONTAINERS=(netalertx teamspeak)
        ENDPOINTS=("http://LANIP:19999:60" "http://LANIP:80:12" "http://LANIP:20211:120")
        ;;
    docker)
        TASKS=(docker netalertx teamspeak)
        SERVICES=(docker)
        ENABLED=()
        CONTAINERS=(netalertx teamspeak)
        ENDPOINTS=("http://LANIP:20211:120")
        ;;
    *)
        echo "Unknown PROVISION_PROFILE '$PROFILE' (expected container, container-system, container-web, full or docker)" >&2
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
        echo "BASE_JOURNAL_MAX_SIZE=50M"
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
                grep -qx 'SystemMaxUse=50M' /etc/systemd/journald.conf.d/10-rpi-setup.conf ||
                    { echo "FAILED: BASE_JOURNAL_MAX_SIZE not applied" >&2; return 1; }
                echo "OK: BASE_TIMEZONE and BASE_JOURNAL_MAX_SIZE applied" ;;
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

wait_url() {
    local url="$1" tries="${2:-60}" i
    for i in $(seq 1 "$tries"); do
        if curl -fsS -o /dev/null "$url"; then
            echo "OK: $url"
            return 0
        fi
        sleep 5
    done
    echo "FAILED: $url not reachable after $tries tries" >&2
    return 1
}

verify_endpoints() {
    echo "=== Verifying web endpoints ==="
    local endpoint url tries lanip
    lanip="$(hostname -I | awk '{print $1}')"
    [[ -n "$lanip" ]] || { echo "FAILED: no LAN address found (hostname -I)" >&2; return 1; }
    for endpoint in "${ENDPOINTS[@]}"; do
        url="${endpoint%:*}"
        url="${url/LANIP/$lanip}"
        tries="${endpoint##*:}"
        wait_url "$url" "$tries"
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
# containers only, mask those generators and units, and print each
# generator's run time so the next slow one shows up in the log. Real Pis and
# the QEMU VM are untouched.
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

time_daemon_reload() {
    local start end
    start="$(date +%s%N)"
    systemctl daemon-reload
    end="$(date +%s%N)"
    echo "=== CI: daemon-reload $1 took $(((end - start) / 1000000)) ms ==="
}

quiet_container_systemd() {
    in_container || return 0
    local g name out start end
    echo "=== CI: masking units and generators that cannot work in this container ==="
    time_daemon_reload before
    echo "=== CI: generator run times ==="
    for g in /usr/lib/systemd/system-generators/*; do
        [[ -x "$g" && ! -d "$g" ]] || continue
        out="$(mktemp -d)"
        start="$(date +%s%N)"
        timeout 60 "$g" "$out" "$out" "$out" >/dev/null 2>&1 || true
        end="$(date +%s%N)"
        rm -rf "$out"
        echo "  $(((end - start) / 1000000)) ms  $g"
    done
    mkdir -p /etc/systemd/system-generators
    for name in "${CONTAINER_MASK_GENERATORS[@]}"; do
        ln -sfn /dev/null "/etc/systemd/system-generators/$name"
    done
    # Plain symlinks instead of "systemctl mask", which reloads once per unit.
    for name in "${CONTAINER_MASK_UNITS[@]}"; do
        ln -sfn /dev/null "/etc/systemd/system/$name"
    done
    time_daemon_reload after
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
