#!/usr/bin/env bash
# NoMercy MediaServer CI — Cross-platform test matrix orchestrator
# Usage: ./run_matrix.sh [release_tag]
#   release_tag: e.g. v0.1.236-perf-improvement (defaults to latest GitHub release)
#
# Runs all Linux LXC tests IN PARALLEL, then Windows sequentially.
# Results are written to /mnt/nomercy-artifacts/<tag>/<run_id>/

set -Eeuo pipefail

########################################
# Bootstrap — source libs and config
########################################

CI_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${CI_ROOT}/config.sh"
source "${CI_ROOT}/lib/util.sh"
source "${CI_ROOT}/lib/lxc.sh"
source "${CI_ROOT}/lib/vm.sh"
source "${CI_ROOT}/lib/verify.sh"
source "${CI_ROOT}/lib/logs.sh"

########################################
# Release tag resolution
########################################

if [[ -n "${1:-}" ]]; then
    RELEASE_TAG="$1"
else
    log "No tag specified — fetching latest release from GitHub API..."
    RELEASE_TAG=$(curl -sf "${GITHUB_API}/releases/latest" \
        | jq -r '.tag_name') \
        || die "Failed to fetch latest release tag from GitHub API"
    log "Latest release: ${RELEASE_TAG}"
fi

########################################
# Run directory setup
########################################

RUN_ID=$(date +%Y%m%d_%H%M%S)
RUN_DIR="${ARTIFACT_ROOT}/${RELEASE_TAG}/${RUN_ID}"
mkdir -p "${RUN_DIR}"

# Export RUN_DIR so util.sh log() can write to ci.log
export RUN_DIR

########################################
# Parallel-safe result tracking
# Each test job writes "DISTRO:PASS" or "DISTRO:FAIL" to this file
########################################

RESULTS_FILE="${RUN_DIR}/results.txt"
touch "${RESULTS_FILE}"

record_result() {
    local name=$1
    local status=$2   # PASS or FAIL
    echo "${name}:${status}" >> "${RESULTS_FILE}"
}

########################################
# Cleanup on exit
########################################

# Track created resources in a temp file (parallel-safe alternative to arrays)
CREATED_FILE="${RUN_DIR}/.created"
touch "${CREATED_FILE}"

cleanup() {
    log "Cleanup starting..."
    while IFS= read -r entry; do
        local type="${entry%%:*}"
        local id="${entry##*:}"
        case "$type" in
            LXC) pct stop "$id" --timeout 10 2>/dev/null || true
                 pct destroy "$id" --purge 2>/dev/null || true ;;
            VM)  qm stop "$id" --timeout 30 2>/dev/null || true
                 qm destroy "$id" --purge 1 2>/dev/null || true ;;
        esac
    done < "${CREATED_FILE}"
    log "Cleanup complete."
}

trap cleanup EXIT

########################################
# Linux LXC test function
########################################

test_lxc() {
    local name=$1
    local template=${LXC_TEMPLATES[$name]}
    local ctid
    ctid=$(get_free_id "$LXC_ID_MIN" "$LXC_ID_MAX")

    log "[${name}] Starting LXC test (CTID ${ctid})"

    # Clone and start container
    if ! lxc_clone "$template" "$ctid" "ci-${name}-${RUN_ID}"; then
        fail "[${name}] Clone failed"
        record_result "$name" "FAIL"
        return
    fi
    echo "LXC:${ctid}" >> "${CREATED_FILE}"

    # Get IP with retry
    local ip
    if ! ip=$(lxc_get_ip "$ctid"); then
        fail "[${name}] Failed to get IP"
        record_result "$name" "FAIL"
        return
    fi
    log "[${name}] IP: ${ip}"

    # Wait for SSH
    if ! wait_for_ssh "$ip" "$SSH_TIMEOUT"; then
        fail "[${name}] SSH timeout"
        record_result "$name" "FAIL"
        return
    fi

    # Copy install script to container and run it
    local install_script="${CI_ROOT}/platforms/install_${name}.sh"
    if [[ ! -f "$install_script" ]]; then
        fail "[${name}] No install script found at ${install_script}"
        record_result "$name" "FAIL"
        return
    fi

    log "[${name}] Copying install script..."
    # shellcheck disable=SC2086
    scp $SSH_OPTS "$install_script" "${SSH_USER}@${ip}:/tmp/install_nomercy.sh"

    log "[${name}] Running install..."
    # shellcheck disable=SC2086
    if ! ssh $SSH_OPTS "${SSH_USER}@${ip}" \
        "bash /tmp/install_nomercy.sh '${RELEASE_TAG}'" \
        >> "${RUN_DIR}/${name}-install-remote.log" 2>&1; then
        fail "[${name}] Install script failed"
        collect_linux_logs "$ip" "$RUN_DIR" "$name"
        record_result "$name" "FAIL"
        return
    fi

    # Verify HTTP/HTTPS endpoint
    log "[${name}] Checking service endpoint..."
    if check_service "$ip" "$WEB_PORT"; then
        log "[${name}] PASSED"
        collect_linux_logs "$ip" "$RUN_DIR" "$name"
        record_result "$name" "PASS"
    else
        fail "[${name}] HTTP check failed after retries"
        collect_linux_logs "$ip" "$RUN_DIR" "$name"
        record_result "$name" "FAIL"
    fi
}

########################################
# Windows VM test function
########################################

test_windows() {
    local win_ver=$1   # win10 or win11
    local template=${WIN_TEMPLATES[$win_ver]}
    local vmid
    vmid=$(get_free_id "$VM_ID_MIN" "$VM_ID_MAX")

    log "[${win_ver}] Starting test (VMID ${vmid})"

    # Clone and start VM
    if ! vm_clone "$template" "$vmid" "ci-${win_ver}-${RUN_ID}"; then
        fail "[${win_ver}] Clone failed"
        record_result "$win_ver" "FAIL"
        return
    fi
    echo "VM:${vmid}" >> "${CREATED_FILE}"

    log "[${win_ver}] Waiting for Windows to boot (30s)..."
    sleep 30

    # Get IP via qemu-guest-agent
    local ip
    if ! ip=$(vm_get_ip "$vmid"); then
        fail "[${win_ver}] Failed to get IP"
        record_result "$win_ver" "FAIL"
        return
    fi
    log "[${win_ver}] IP: ${ip}"

    # Wait for SSH (Windows boots slowly)
    if ! wait_for_ssh "$ip" 300; then
        fail "[${win_ver}] SSH timeout"
        record_result "$win_ver" "FAIL"
        return
    fi

    # Create CI directory on Windows
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "${SSH_USER}@${ip}" \
        'powershell -Command "New-Item -ItemType Directory -Force -Path C:\ci | Out-Null"'

    # Copy PowerShell install script to VM
    log "[${win_ver}] Copying install script..."
    # shellcheck disable=SC2086
    scp $SSH_OPTS "${CI_ROOT}/platforms/install_windows.ps1" \
        "${SSH_USER}@${ip}:C:/ci/install_windows.ps1"

    # Run install script
    log "[${win_ver}] Running install..."
    # shellcheck disable=SC2086
    if ! ssh $SSH_OPTS "${SSH_USER}@${ip}" \
        "powershell -ExecutionPolicy Bypass -File C:\\ci\\install_windows.ps1 -ReleaseTag '${RELEASE_TAG}'" \
        >> "${RUN_DIR}/${win_ver}-install-remote.log" 2>&1; then
        fail "[${win_ver}] Install script failed"
        collect_windows_logs "$ip" "$RUN_DIR"
        record_result "$win_ver" "FAIL"
        return
    fi

    # Verify endpoint
    log "[${win_ver}] Checking service endpoint..."
    if check_service "$ip" "$WEB_PORT"; then
        log "[${win_ver}] PASSED"
        collect_windows_logs "$ip" "$RUN_DIR"
        record_result "$win_ver" "PASS"
    else
        fail "[${win_ver}] HTTP check failed after retries"
        collect_windows_logs "$ip" "$RUN_DIR"
        record_result "$win_ver" "FAIL"
    fi
}

########################################
# Matrix execution
########################################

log "=========================================="
log " NoMercy MediaServer CI"
log " Release : ${RELEASE_TAG}"
log " Run ID  : ${RUN_ID}"
log " Artifacts: ${RUN_DIR}"
log "=========================================="

# Run all Linux LXC tests IN PARALLEL
declare -a LXC_PIDS=()
for distro in "${!LXC_TEMPLATES[@]}"; do
    test_lxc "$distro" &
    LXC_PIDS+=($!)
done

# Wait for all Linux jobs to complete
for pid in "${LXC_PIDS[@]}"; do
    wait "$pid" || true
done

log "All Linux tests complete. Starting Windows tests..."

# Windows VMs run sequentially (resource-heavy)
for win_ver in "${!WIN_TEMPLATES[@]}"; do
    test_windows "$win_ver"
done

########################################
# Summary table
########################################

log ""
log "=========================================="
log " TEST MATRIX RESULTS"
log "=========================================="
log " Platform       | Result"
log " ---------------+-------"

OVERALL_PASS=1
while IFS=: read -r name status; do
    if [[ "$status" == "PASS" ]]; then
        log " $(printf '%-15s' "$name")| PASS"
    else
        log " $(printf '%-15s' "$name")| FAIL  <--"
        OVERALL_PASS=0
    fi
done < "${RESULTS_FILE}"

log "=========================================="
log " Artifacts: ${RUN_DIR}"
log "=========================================="

if [[ "$OVERALL_PASS" -eq 1 ]]; then
    log "Matrix completed successfully."
    exit 0
else
    log "Matrix completed WITH FAILURES."
    exit 1
fi
