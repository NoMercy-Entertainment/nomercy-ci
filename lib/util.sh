#!/usr/bin/env bash
# Shared utility functions — source this in all lib scripts

# RUN_DIR must be set by the caller before sourcing this file

log() {
    local msg="[$(date '+%H:%M:%S')] $*"
    echo "$msg"
    if [[ -n "${RUN_DIR:-}" ]]; then
        echo "$msg" >> "${RUN_DIR}/ci.log"
    fi
}

fail() {
    log "ERROR: $*"
}

die() {
    log "FATAL: $*"
    exit 1
}

# retry <attempts> <delay_seconds> <command...>
retry() {
    local attempts=$1
    local delay=$2
    shift 2
    local i
    for ((i=1; i<=attempts; i++)); do
        if "$@"; then
            return 0
        fi
        if (( i < attempts )); then
            sleep "$delay"
        fi
    done
    return 1
}

# wait_for_ssh <ip> [timeout_seconds]
wait_for_ssh() {
    local ip=$1
    local timeout=${2:-$SSH_TIMEOUT}
    local start
    start=$(date +%s)

    log "Waiting for SSH at ${ip} (timeout ${timeout}s)..."
    while true; do
        # shellcheck disable=SC2086
        if ssh $SSH_OPTS "${SSH_USER}@${ip}" "echo ready" >/dev/null 2>&1; then
            log "SSH ready at ${ip}"
            return 0
        fi
        if (( $(date +%s) - start > timeout )); then
            fail "SSH timeout after ${timeout}s at ${ip}"
            return 1
        fi
        sleep 5
    done
}

# get_free_id <min> <max>
# Queries Proxmox cluster for used VMIDs and returns the first free one in range
get_free_id() {
    local min=$1
    local max=$2
    local used
    used=$(pvesh get /cluster/resources --type vm 2>/dev/null \
        | jq -r '.[].vmid // empty' | sort -n)

    local id
    for ((id=min; id<=max; id++)); do
        if ! echo "$used" | grep -qx "$id"; then
            echo "$id"
            return 0
        fi
    done

    die "No free VMID available in range ${min}-${max}"
}

# extract_version <release_tag>
# Extracts numeric semver from tags like "v0.1.236-perf-improvement" → "0.1.236"
extract_version() {
    local tag=$1
    local ver="${tag#v}"          # strip leading v
    echo "${ver%%-*}"            # strip branch suffix after first hyphen
}
