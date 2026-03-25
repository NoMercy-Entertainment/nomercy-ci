#!/usr/bin/env bash
# KVM virtual machine lifecycle management

_VM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_VM_DIR}/../config.sh"
source "${_VM_DIR}/util.sh"

# vm_check_template <vmid>
vm_check_template() {
    local template=$1
    if ! qm config "$template" >/dev/null 2>&1; then
        die "VM template ${template} does not exist. Run setup/setup_windows_template.sh first."
    fi
}

# vm_clone <template_vmid> <new_vmid> <name>
vm_clone() {
    local template=$1
    local vmid=$2
    local name=$3

    vm_check_template "$template"
    log "Cloning VM template ${template} → ${vmid} (${name})"
    qm clone "$template" "$vmid" --name "$name" --full 1
    qm set "$vmid" --cores "$WIN_CORES" --memory "$WIN_MEM"
    qm start "$vmid"
    log "VM ${vmid} started"
}

# vm_get_ip <vmid>
# Queries qemu-guest-agent for a non-loopback IPv4 address
# Retries for up to 90 seconds (Windows boots slowly)
vm_get_ip() {
    local vmid=$1
    local ip=""
    local i

    for ((i=0; i<30; i++)); do
        ip=$(qm guest cmd "$vmid" network-get-interfaces 2>/dev/null \
            | jq -r '
                [.[].["ip-addresses"][]
                 | select(.["ip-address-type"] == "ipv4")
                 | .["ip-address"]
                 | select(startswith("127.") | not)]
                | first // empty')
        if [[ -n "$ip" ]]; then
            echo "$ip"
            return 0
        fi
        sleep 3
    done

    fail "Could not get IP for VM ${vmid} after 90s"
    return 1
}

# vm_destroy <vmid>
vm_destroy() {
    local vmid=$1
    log "Destroying VM ${vmid}"
    qm stop "$vmid" --timeout 30 2>/dev/null || true
    qm destroy "$vmid" --purge 1 2>/dev/null || true
}
