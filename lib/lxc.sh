#!/usr/bin/env bash
# LXC container lifecycle management

_LXC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_LXC_DIR}/../config.sh"
source "${_LXC_DIR}/util.sh"

# lxc_check_template <ctid>
lxc_check_template() {
    local template=$1
    if ! pct config "$template" >/dev/null 2>&1; then
        die "LXC template ${template} does not exist. Run setup/setup_templates.sh first."
    fi
}

# lxc_clone <template_ctid> <new_ctid> <hostname>
lxc_clone() {
    local template=$1
    local ctid=$2
    local name=$3

    lxc_check_template "$template"
    log "Cloning LXC template ${template} → ${ctid} (${name})"
    pct clone "$template" "$ctid" --hostname "$name"
    pct set "$ctid" --cores "$LXC_CORES" --memory "$LXC_MEM"
    pct start "$ctid"
    log "LXC ${ctid} started"
}

# lxc_get_ip <ctid>
# Retries for up to 20 seconds waiting for the container to acquire an IP
lxc_get_ip() {
    local ctid=$1
    local ip=""
    local i

    for ((i=0; i<10; i++)); do
        ip=$(pct exec "$ctid" -- ip -4 addr show eth0 2>/dev/null \
            | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
        if [[ -n "$ip" ]]; then
            echo "$ip"
            return 0
        fi
        sleep 2
    done

    fail "Could not get IP for LXC ${ctid} after 20s"
    return 1
}

# lxc_destroy <ctid>
lxc_destroy() {
    local ctid=$1
    log "Destroying LXC ${ctid}"
    pct stop "$ctid" --timeout 10 2>/dev/null || true
    pct destroy "$ctid" --purge 2>/dev/null || true
}
