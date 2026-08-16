#!/usr/bin/env bash
set -euo pipefail

# Shared provisioning and verification logic for CI
# Used by both provision-gate (nspawn) and provision-qemu (QEMU) jobs

# Tasks to provision - single source of truth
TASKS=(
    base
    docker
    samba
    web
    monitoring
    pihole
    netalertx
    teamspeak
)

# Service verification list
SERVICES=(
    docker
    smbd
    nginx
    netdata
    fail2ban
)

# Web endpoint verification: "url:max_tries"
ENDPOINTS=(
    "http://localhost:19999:60"
    "http://localhost:20211:120"
)

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