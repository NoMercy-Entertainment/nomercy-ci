#!/usr/bin/env bash
# Destroy all runner VMs and deregister from GitHub
#
# Usage:
#   ./runners/destroy_runners.sh              # destroy all
#   ./runners/destroy_runners.sh linux         # destroy linux runners only
#   ./runners/destroy_runners.sh --vm 5103     # destroy specific VMID

set -Eeuo pipefail

CI_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${CI_ROOT}/config.sh"
source "${CI_ROOT}/lib/util.sh"

RUN_DIR="/tmp/nomercy-runner-destroy-$$"
mkdir -p "$RUN_DIR"
export RUN_DIR

FILTER="${1:-all}"

[[ -n "$RUNNER_GH_TOKEN" ]] || die "RUNNER_GH_TOKEN not set."

########################################
# Deregister runners from GitHub
########################################

deregister_github_runners() {
    local name_filter="${1:-runner-}"

    log "Fetching registered runners from GitHub..."
    local runners
    runners=$(curl -sS \
        -H "Authorization: Bearer ${RUNNER_GH_TOKEN}" \
        "https://api.github.com/orgs/${RUNNER_ORG}/actions/runners?per_page=100" \
        | jq -r ".runners[] | select(.name | startswith(\"${name_filter}\")) | \"\(.id) \(.name) \(.status)\"")

    if [[ -z "$runners" ]]; then
        log "No matching runners found in GitHub."
        return
    fi

    while IFS=' ' read -r id name status; do
        log "Deregistering ${name} (ID ${id}, ${status})..."
        curl -sS -X DELETE \
            -H "Authorization: Bearer ${RUNNER_GH_TOKEN}" \
            "https://api.github.com/orgs/${RUNNER_ORG}/actions/runners/${id}" \
            || log "Warning: failed to deregister ${name}"
    done <<< "$runners"
}

########################################
# Destroy Proxmox VMs
########################################

destroy_runner_vms() {
    local name_filter="${1:-runner-}"

    log "Finding runner VMs in range ${RUNNER_ID_MIN}-${RUNNER_ID_MAX}..."
    for ((vmid=RUNNER_ID_MIN; vmid<=RUNNER_ID_MAX; vmid++)); do
        if qm config "$vmid" >/dev/null 2>&1; then
            local vm_name
            vm_name=$(qm config "$vmid" | grep '^name:' | awk '{print $2}')
            if [[ "$vm_name" == ${name_filter}* ]]; then
                log "Destroying VM ${vmid} (${vm_name})..."
                qm stop "$vmid" --timeout 15 2>/dev/null || true
                qm destroy "$vmid" --purge 1 2>/dev/null || true
            fi
        fi
    done
}

########################################
# Main
########################################

case "$FILTER" in
    --vm)
        vmid="${2:?Usage: $0 --vm <VMID>}"
        log "Destroying single VM ${vmid}..."
        qm stop "$vmid" --timeout 15 2>/dev/null || true
        qm destroy "$vmid" --purge 1 2>/dev/null || true
        ;;
    linux|macos|windows)
        deregister_github_runners "runner-${FILTER}-"
        destroy_runner_vms "runner-${FILTER}-"
        ;;
    all)
        deregister_github_runners "runner-"
        destroy_runner_vms "runner-"
        ;;
    *)
        die "Usage: $0 <all|linux|macos|windows|--vm VMID>"
        ;;
esac

log "Done."
