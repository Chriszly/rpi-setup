#!/usr/bin/env bash
set -euo pipefail

# Shared provisioning and verification logic for CI
# Used by both provision-gate (nspawn) and provision-qemu (QEMU) jobs

# Tasks to provision - single source of truth
# Container-friendly tasks (work in systemd-nspawn without Docker)
TASKS_CONTAINER=(
    base
    samba
    web
    monitoring
    pihole
)

# Full task list including Docker-dependent tasks (for QEMU VM)
TASKS_FULL=(
    base
    docker
    samba
    web
    monitoring
    pihole
    netalertx
    teamspeak
)

# Detect container environment and select appropriate task list
if [[ -f /run/systemd/container ]] || grep -q 'container' /proc/1/cgroup 2>/dev/null; then
    TASKS=("${TASKS_CONTAINER[@]}")
else
    TASKS=("${TASKS_FULL[@]}")
fi

# Service verification list (container-friendly)
SERVICES_CONTAINER=(
    smbd
    nginx
    netdata
    fail2ban
)

# Full service verification list (including Docker)
SERVICES_FULL=(
    docker
    smbd
    nginx
    netdata
    fail2ban
)

# Web endpoint verification: "url:max_tries" (container-friendly)
ENDPOINTS_CONTAINER=(
    "http://localhost:19999:60"
)

# Full web endpoint verification (including netalertx)
ENDPOINTS_FULL=(
    "http://localhost:19999:60"
    "http://localhost:20211:120"
)

# Select appropriate lists based on environment
if [[ -f /run/systemd/container ]] || grep -q 'container' /proc/1/cgroup 2>/dev/null; then
    SERVICES=("${SERVICES_CONTAINER[@]}")
    ENDPOINTS=("${ENDPOINTS_CONTAINER[@]}")
else
    SERVICES=("${SERVICES_FULL[@]}")
    ENDPOINTS=("${ENDPOINTS_FULL[@]}")
fi

run_provisioning() {
    local workdir="$1"
    cd "$workdir"

    export PIHOLE_CONFIRM=yes
    export SAMBA_PASSWORD=testpw

    echo "=== Provisioning ==="
    bash setup.sh "${TASKS[@]}"
}

verify_services() {
    echo "=== Verifying services ==="
    for svc in "${SERVICES[@]}"; do
        systemctl is-active "$svc"
    done
}

verify_containers() {
    if [[ -f /run/systemd/container ]] || grep -q 'container' /proc/1/cgroup 2>/dev/null; then
        echo "=== Skipping container verification in container environment ==="
        return
    fi
    echo "=== Verifying containers ==="
    docker ps
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
    echo "FAILED: $url not reachable" >&2
    return 1
}

verify_endpoints() {
    echo "=== Verifying web endpoints ==="
    for endpoint in "${ENDPOINTS[@]}"; do
        IFS=':' read -r url tries <<< "$endpoint"
        wait_url "$url" "$tries"
    done
}

run_idempotency() {
    local workdir="$1"
    cd "$workdir"

    echo "=== Idempotency re-run ==="
    export PIHOLE_CONFIRM=yes
    export SAMBA_PASSWORD=testpw
    bash setup.sh "${TASKS[@]}"
}

main() {
    local workdir="${1:-/workspace}"

    run_provisioning "$workdir"
    verify_services
    verify_containers
    verify_endpoints
    run_idempotency "$workdir"

    echo "=== All checks passed ==="
}

main "$@"