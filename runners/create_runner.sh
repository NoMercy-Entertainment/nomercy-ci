#!/usr/bin/env bash
# Create and register GitHub Actions self-hosted runners on Proxmox
#
# Usage:
#   ./runners/create_runner.sh linux [count]     # default 1
#   ./runners/create_runner.sh macos [count]
#   ./runners/create_runner.sh windows [count]
#   ./runners/create_runner.sh all [count]       # one of each
#
# Prerequisites:
#   - Runner templates created by setup/setup_runner_templates.sh
#   - RUNNER_GH_TOKEN set (PAT with admin:org scope)

set -Eeuo pipefail

CI_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${CI_ROOT}/config.sh"
source "${CI_ROOT}/lib/util.sh"
source "${CI_ROOT}/lib/vm.sh"

RUN_DIR="${RUN_DIR:-/tmp/nomercy-runner-$$}"
mkdir -p "$RUN_DIR"
export RUN_DIR

OS_TYPE="${1:-}"
COUNT="${2:-1}"

[[ -n "$OS_TYPE" ]] || die "Usage: $0 <linux|macos|windows|all> [count]"
[[ -n "$RUNNER_GH_TOKEN" ]] || die "RUNNER_GH_TOKEN not set in .env"
[[ -n "$RUNNER_ORG" ]] || die "RUNNER_ORG not set in .env"
[[ -n "$RUNNER_VERSION" ]] || die "RUNNER_VERSION not set in .env"

########################################
# Get registration token from GitHub
########################################

get_reg_token() {
    local response
    response=$(curl -sS -X POST \
        -H "Authorization: Bearer ${RUNNER_GH_TOKEN}" \
        "https://api.github.com/orgs/${RUNNER_ORG}/actions/runners/registration-token")

    local token
    token=$(echo "$response" | jq -r '.token // empty')
    if [[ -z "$token" ]]; then
        die "Failed to get registration token: $(echo "$response" | jq -r '.message // "unknown error"')"
    fi
    echo "$token"
}

########################################
# Create a single runner VM
########################################

create_runner() {
    local os=$1
    local index=$2
    local template=${RUNNER_TEMPLATES[$os]}
    local vmid
    vmid=$(get_free_id "$RUNNER_ID_MIN" "$RUNNER_ID_MAX")

    local name="runner-${os}-${index}"
    local cores mem labels

    case "$os" in
        linux)
            cores=$RUNNER_LINUX_CORES
            mem=$RUNNER_LINUX_MEM
            labels=$RUNNER_LINUX_LABELS
            ;;
        macos)
            cores=$RUNNER_MACOS_CORES
            mem=$RUNNER_MACOS_MEM
            labels=$RUNNER_MACOS_LABELS
            ;;
        windows)
            cores=$RUNNER_WINDOWS_CORES
            mem=$RUNNER_WINDOWS_MEM
            labels=$RUNNER_WINDOWS_LABELS
            ;;
        *)
            die "Unknown OS type: $os"
            ;;
    esac

    # Check template exists
    if ! qm config "$template" >/dev/null 2>&1; then
        die "Template ${template} (${os}) not found. Run setup/setup_runner_templates.sh first."
    fi

    log "[${name}] Cloning template ${template} → VMID ${vmid}"
    qm clone "$template" "$vmid" --name "$name"
    qm set "$vmid" --cores "$cores" --memory "$mem"
    qm start "$vmid"

    log "[${name}] Waiting for VM to boot..."
    local ip=""
    case "$os" in
        linux)
            sleep 15
            ip=$(vm_get_ip "$vmid")
            wait_for_ssh "$ip" 120
            ;;
        macos)
            sleep 30
            ip=$(vm_get_ip "$vmid")
            wait_for_ssh "$ip" 180
            ;;
        windows)
            sleep 45
            ip=$(vm_get_ip "$vmid")
            wait_for_ssh "$ip" 300
            ;;
    esac

    [[ -n "$ip" ]] || die "[${name}] Could not get IP"
    log "[${name}] IP: ${ip}"

    # Get a fresh registration token
    local reg_token
    reg_token=$(get_reg_token)

    # Register runner
    log "[${name}] Registering with GitHub..."
    case "$os" in
        linux|macos)
            # shellcheck disable=SC2086
            ssh $SSH_OPTS "${SSH_USER}@${ip}" bash -s <<RUNNER_EOF
set -e
cd /opt/actions-runner

./config.sh --unattended \\
    --url "https://github.com/${RUNNER_ORG}" \\
    --token "${reg_token}" \\
    --name "${name}" \\
    --labels "${labels}" \\
    --runnergroup "${RUNNER_GROUP}" \\
    --replace

sudo ./svc.sh install ${SSH_USER}
sudo ./svc.sh start
echo "Runner ${name} registered and started."
RUNNER_EOF
            ;;
        windows)
            # shellcheck disable=SC2086
            ssh $SSH_OPTS "${SSH_USER}@${ip}" powershell -Command "
                Set-Location C:\\actions-runner
                .\\config.cmd --unattended \`
                    --url 'https://github.com/${RUNNER_ORG}' \`
                    --token '${reg_token}' \`
                    --name '${name}' \`
                    --labels '${labels}' \`
                    --runnergroup '${RUNNER_GROUP}' \`
                    --replace
                .\\svc.cmd install
                .\\svc.cmd start
                Write-Host 'Runner ${name} registered and started.'
            "
            ;;
    esac

    log "[${name}] ✓ Online (VMID ${vmid}, IP ${ip})"
}

########################################
# Main
########################################

log "=========================================="
log " NoMercy Runner Provisioner"
log " OS: ${OS_TYPE}  Count: ${COUNT}"
log "=========================================="

if [[ "$OS_TYPE" == "all" ]]; then
    for os in linux macos windows; do
        for ((i=1; i<=COUNT; i++)); do
            create_runner "$os" "$i"
        done
    done
else
    for ((i=1; i<=COUNT; i++)); do
        create_runner "$OS_TYPE" "$i"
    done
fi

log "=========================================="
log " All runners created."
log " Verify at: https://github.com/organizations/${RUNNER_ORG}/settings/actions/runners"
log "=========================================="
