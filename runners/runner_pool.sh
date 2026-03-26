#!/usr/bin/env bash
# Ephemeral runner pool manager for Proxmox
# Maintains N runners. Each runner picks up one job, then gets destroyed
# and replaced with a fresh clone. Clean state every job.
#
# Usage:
#   ./runners/runner_pool.sh linux 5      # maintain 5 Linux runners
#   ./runners/runner_pool.sh linux 5 &    # run in background
#
# Stop with: kill $(cat /tmp/nomercy-runner-pool.pid)

set -Euo pipefail

CI_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${CI_ROOT}/config.sh"
source "${CI_ROOT}/lib/util.sh"

RUN_DIR="/var/log/nomercy-runners"
mkdir -p "$RUN_DIR"
export RUN_DIR

OS_TYPE="${1:-}"
POOL_SIZE="${2:-3}"

[[ -n "$OS_TYPE" ]] || { echo "Usage: $0 <linux|macos|windows> <pool_size>"; exit 1; }
[[ -n "$RUNNER_GH_TOKEN" ]] || { echo "RUNNER_GH_TOKEN not set in .env"; exit 1; }
[[ -n "$RUNNER_ORG" ]] || { echo "RUNNER_ORG not set in .env"; exit 1; }

echo $$ > /tmp/nomercy-runner-pool.pid

log "=========================================="
log " NoMercy Ephemeral Runner Pool"
log " OS: ${OS_TYPE}  Pool size: ${POOL_SIZE}"
log "=========================================="

########################################
# GitHub API helpers
########################################

get_reg_token() {
    local response
    response=$(curl -sS -X POST \
        -H "Authorization: Bearer ${RUNNER_GH_TOKEN}" \
        "https://api.github.com/orgs/${RUNNER_ORG}/actions/runners/registration-token")

    if ! echo "$response" | jq . >/dev/null 2>&1; then
        log "ERROR: GitHub API returned invalid response"
        return 1
    fi

    local token
    token=$(echo "$response" | jq -r '.token // empty')
    if [[ -z "$token" ]]; then
        log "ERROR: No registration token: $(echo "$response" | jq -r '.message // "unknown"')"
        return 1
    fi
    echo "$token"
}

########################################
# Runner lifecycle
########################################

get_runner_config() {
    case "$OS_TYPE" in
        linux)
            RUNNER_CORES=$RUNNER_LINUX_CORES
            RUNNER_MEM=$RUNNER_LINUX_MEM
            RUNNER_LABELS=$RUNNER_LINUX_LABELS
            ;;
        macos)
            RUNNER_CORES=$RUNNER_MACOS_CORES
            RUNNER_MEM=$RUNNER_MACOS_MEM
            RUNNER_LABELS=$RUNNER_MACOS_LABELS
            ;;
        windows)
            RUNNER_CORES=$RUNNER_WINDOWS_CORES
            RUNNER_MEM=$RUNNER_WINDOWS_MEM
            RUNNER_LABELS=$RUNNER_WINDOWS_LABELS
            ;;
    esac
}

# spawn_runner <slot_number>
# Clones template, boots, registers as ephemeral runner, waits for job to finish,
# then destroys and returns.
spawn_runner() {
    local slot=$1
    local name="runner-${OS_TYPE}-${slot}"
    local template=${RUNNER_TEMPLATES[$OS_TYPE]}
    local ctid

    ctid=$(get_free_id "$RUNNER_ID_MIN" "$RUNNER_ID_MAX") || {
        log "[${name}] No free ID available"
        return 1
    }

    log "[${name}] Spawning (CTID ${ctid})..."

    # Clone
    if [[ "$OS_TYPE" == "linux" ]]; then
        pct clone "$template" "$ctid" --hostname "$name" --full || {
            log "[${name}] Clone failed"
            return 1
        }
        pct set "$ctid" --cores "$RUNNER_CORES" --memory "$RUNNER_MEM"
        pct start "$ctid"

        sleep 5
        local ip=""
        for attempt in $(seq 1 20); do
            ip=$(pct exec "$ctid" -- hostname -I 2>/dev/null | awk '{print $1}') || true
            if [[ -n "$ip" && "$ip" != *":"* ]]; then break; fi
            ip=""
            sleep 3
        done

        if [[ -z "$ip" ]]; then
            log "[${name}] Could not get IP — destroying"
            pct stop "$ctid" 2>/dev/null || true
            pct destroy "$ctid" --purge 2>/dev/null || true
            return 1
        fi
    else
        # macOS/Windows use VMs
        qm clone "$template" "$ctid" --name "$name" || {
            log "[${name}] Clone failed"
            return 1
        }
        qm set "$ctid" --cores "$RUNNER_CORES" --memory "$RUNNER_MEM"
        qm start "$ctid"

        local ip=""
        local wait_time=30
        [[ "$OS_TYPE" == "windows" ]] && wait_time=45
        sleep "$wait_time"

        ip=$(qm guest cmd "$ctid" network-get-interfaces 2>/dev/null \
            | jq -r '[.[].["ip-addresses"][]|select(.["ip-address-type"]=="ipv4")|.["ip-address"]|select(startswith("127.")|not)]|first//empty' 2>/dev/null) || true

        if [[ -z "$ip" ]]; then
            log "[${name}] Could not get IP — destroying"
            qm stop "$ctid" 2>/dev/null || true
            qm destroy "$ctid" --purge 1 2>/dev/null || true
            return 1
        fi
    fi

    log "[${name}] IP: ${ip}"

    # Wait for SSH
    local ssh_timeout=60
    [[ "$OS_TYPE" == "windows" ]] && ssh_timeout=300
    [[ "$OS_TYPE" == "macos" ]] && ssh_timeout=180

    local start_time
    start_time=$(date +%s)
    while true; do
        # shellcheck disable=SC2086
        if ssh $SSH_OPTS "${SSH_USER}@${ip}" "echo ready" >/dev/null 2>&1; then
            break
        fi
        if (( $(date +%s) - start_time > ssh_timeout )); then
            log "[${name}] SSH timeout — destroying"
            destroy_resource "$ctid"
            return 1
        fi
        sleep 3
    done

    # Get registration token
    local reg_token
    reg_token=$(get_reg_token) || {
        log "[${name}] Failed to get token — destroying"
        destroy_resource "$ctid"
        return 1
    }

    # Register as ephemeral runner (--ephemeral = exits after one job)
    log "[${name}] Registering as ephemeral runner..."
    if [[ "$OS_TYPE" == "linux" || "$OS_TYPE" == "macos" ]]; then
        # shellcheck disable=SC2086
        ssh $SSH_OPTS "${SSH_USER}@${ip}" bash -s <<RUNNER_EOF
set -e
cd /opt/actions-runner
./config.sh --unattended \\
    --url "https://github.com/${RUNNER_ORG}" \\
    --token "${reg_token}" \\
    --name "${name}" \\
    --labels "${RUNNER_LABELS}" \\
    --runnergroup "${RUNNER_GROUP}" \\
    --ephemeral \\
    --replace
RUNNER_EOF
    else
        # shellcheck disable=SC2086
        ssh $SSH_OPTS "${SSH_USER}@${ip}" powershell -Command "
            Set-Location C:\\actions-runner
            .\\config.cmd --unattended \`
                --url 'https://github.com/${RUNNER_ORG}' \`
                --token '${reg_token}' \`
                --name '${name}' \`
                --labels '${RUNNER_LABELS}' \`
                --runnergroup '${RUNNER_GROUP}' \`
                --ephemeral \`
                --replace
        "
    fi

    # Start the runner and wait for it to finish (it exits after one job)
    log "[${name}] Waiting for a job..."
    if [[ "$OS_TYPE" == "linux" || "$OS_TYPE" == "macos" ]]; then
        # shellcheck disable=SC2086
        ssh $SSH_OPTS -o ServerAliveInterval=30 "${SSH_USER}@${ip}" \
            "cd /opt/actions-runner && ./run.sh" 2>&1 \
            | tee -a "${RUN_DIR}/${name}.log" || true
    else
        # shellcheck disable=SC2086
        ssh $SSH_OPTS -o ServerAliveInterval=30 "${SSH_USER}@${ip}" \
            "powershell -Command 'Set-Location C:\\actions-runner; .\\run.cmd'" 2>&1 \
            | tee -a "${RUN_DIR}/${name}.log" || true
    fi

    log "[${name}] Job completed — destroying"
    destroy_resource "$ctid"
}

destroy_resource() {
    local id=$1
    if [[ "$OS_TYPE" == "linux" ]]; then
        pct stop "$id" --timeout 10 2>/dev/null || true
        pct destroy "$id" --purge 2>/dev/null || true
    else
        qm stop "$id" --timeout 30 2>/dev/null || true
        qm destroy "$id" --purge 1 2>/dev/null || true
    fi
}

########################################
# Pool manager — maintain N runners
########################################

get_runner_config

# Cleanup on exit
cleanup() {
    log "Pool shutting down..."
    # Kill all background spawn jobs
    jobs -p | xargs -r kill 2>/dev/null || true
    wait 2>/dev/null || true
    rm -f /tmp/nomercy-runner-pool.pid
    log "Pool stopped."
}
trap cleanup EXIT INT TERM

# Track slot availability
declare -A SLOT_PIDS

log "Starting pool..."

while true; do
    for ((slot=1; slot<=POOL_SIZE; slot++)); do
        pid=${SLOT_PIDS[$slot]:-}

        # Check if slot is free (no PID or process finished)
        if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
            # Slot is free — spawn a new ephemeral runner
            spawn_runner "$slot" &
            SLOT_PIDS[$slot]=$!
            log "Slot ${slot} → PID ${SLOT_PIDS[$slot]}"
        fi
    done

    # Check every 10 seconds for finished slots
    sleep 10
done
