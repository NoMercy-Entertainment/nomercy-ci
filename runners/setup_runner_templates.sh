#!/usr/bin/env bash
# Create Proxmox VM templates for GitHub Actions self-hosted runners
#
# Usage:
#   ./runners/setup_runner_templates.sh [linux|macos|windows|all]
#
# Creates VM templates with all CI tools pre-installed.
# Clone these templates with create_runner.sh to spin up runners.

set -Eeuo pipefail

CI_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${CI_ROOT}/config.sh"
source "${CI_ROOT}/lib/util.sh"
source "${CI_ROOT}/lib/vm.sh"

RUN_DIR="${RUN_DIR:-/tmp/nomercy-runner-setup-$$}"
mkdir -p "$RUN_DIR"
export RUN_DIR

SSH_PUB_KEY="${CI_ROOT}/.ssh/ci_ed25519.pub"
[[ -f "$SSH_PUB_KEY" ]] || die "SSH key not found at ${SSH_PUB_KEY}"
PUB_KEY=$(cat "$SSH_PUB_KEY")

STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
TARGET="${1:-all}"

########################################
# Linux runner template (Ubuntu 24.04)
########################################

setup_linux_template() {
    local vmid=${RUNNER_TEMPLATES[linux]}
    local name="runner-linux-template"

    log "=== Linux Runner Template (VMID ${vmid}) ==="

    # Remove existing
    if qm config "$vmid" >/dev/null 2>&1; then
        log "Removing existing template ${vmid}..."
        qm stop "$vmid" 2>/dev/null || true
        sleep 2
        qm destroy "$vmid" --purge 1 2>/dev/null || true
    fi

    # Download cloud image
    local img="/var/lib/vz/template/iso/ubuntu-24.04-cloudimg.img"
    if [[ ! -f "$img" ]]; then
        log "Downloading Ubuntu 24.04 cloud image..."
        curl -fSL "$RUNNER_LINUX_IMAGE" -o "$img"
    fi

    # Create VM
    log "Creating VM..."
    qm create "$vmid" \
        --name "$name" \
        --ostype l26 \
        --cores "$RUNNER_LINUX_CORES" \
        --memory "$RUNNER_LINUX_MEM" \
        --net0 "virtio,bridge=${BRIDGE}" \
        --scsihw virtio-scsi-single \
        --agent enabled=1

    # Import disk
    qm set "$vmid" --scsi0 "${STORAGE}:0,import-from=${img},discard=on,ssd=1"
    qm resize "$vmid" scsi0 50G
    qm set "$vmid" --boot order=scsi0

    # Cloud-init
    qm set "$vmid" --ide2 "${STORAGE}:cloudinit"
    qm set "$vmid" --ciuser "$SSH_USER"
    qm set "$vmid" --sshkeys "$SSH_PUB_KEY"
    qm set "$vmid" --ipconfig0 "ip=dhcp"
    qm set "$vmid" --ciupgrade 1

    # Start and wait for SSH
    qm start "$vmid"
    log "Waiting for VM to boot..."
    sleep 20
    local ip
    ip=$(vm_get_ip "$vmid")
    wait_for_ssh "$ip" 120

    # Install all tools
    log "Installing CI tools..."
    # shellcheck disable=SC2086
    scp $SSH_OPTS "${CI_ROOT}/runners/install_linux_runner.sh" "${SSH_USER}@${ip}:/tmp/install.sh"
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "${SSH_USER}@${ip}" "chmod +x /tmp/install.sh && sudo /tmp/install.sh '${RUNNER_VERSION}'" \
        2>&1 | tee "${RUN_DIR}/linux-install.log"

    # Stop and convert to template
    log "Converting to template..."
    qm stop "$vmid"
    sleep 5
    qm set "$vmid" --template 1
    log "Linux runner template ready (VMID ${vmid})"
}

########################################
# macOS runner template
########################################

setup_macos_template() {
    local vmid=${RUNNER_TEMPLATES[macos]}
    local name="runner-macos-template"

    log "=== macOS Runner Template (VMID ${vmid}) ==="

    if qm config "$vmid" >/dev/null 2>&1; then
        log "Removing existing template ${vmid}..."
        qm stop "$vmid" 2>/dev/null || true
        sleep 2
        qm destroy "$vmid" --purge 1 2>/dev/null || true
    fi

    # macOS requires manual ISO preparation + OSK passthrough
    # The ISO must be prepared separately (e.g. via macOS-Simple-KVM or OSX-KVM)
    log "Creating macOS VM shell..."
    qm create "$vmid" \
        --name "$name" \
        --ostype other \
        --cores "$RUNNER_MACOS_CORES" \
        --memory "$RUNNER_MACOS_MEM" \
        --net0 "vmxnet3,bridge=${BRIDGE}" \
        --scsihw virtio-scsi-single \
        --bios ovmf \
        --machine q35 \
        --cpu host \
        --args "-device isa-applesmc,osk=$(cat /opt/nomercy-ci/.osk 2>/dev/null || echo 'INSERT_OSK_HERE')" \
        --agent enabled=1

    # Create disk
    qm set "$vmid" --scsi0 "${STORAGE}:64,discard=on,ssd=1"
    qm set "$vmid" --ide0 "${RUNNER_MACOS_ISO},media=cdrom"
    qm set "$vmid" --boot "order=ide0;scsi0"
    qm set "$vmid" --efidisk0 "${STORAGE}:1"

    log ""
    log "┌─────────────────────────────────────────────────────────┐"
    log "│ macOS template created as VM ${vmid} but NOT installed. │"
    log "│                                                         │"
    log "│ Manual steps required:                                  │"
    log "│ 1. Boot VM from Proxmox console                        │"
    log "│ 2. Install macOS from the ISO                          │"
    log "│ 3. Enable SSH: System Settings → General → Sharing     │"
    log "│ 4. Create user '${SSH_USER}' with sudo access          │"
    log "│ 5. Install SSH key:                                    │"
    log "│    mkdir -p ~/.ssh                                     │"
    log "│    echo '${PUB_KEY}' >> ~/.ssh/authorized_keys         │"
    log "│ 6. Run: runners/install_macos_runner.sh on the VM      │"
    log "│ 7. Shut down and convert:                              │"
    log "│    qm set ${vmid} --template 1                         │"
    log "└─────────────────────────────────────────────────────────┘"
}

########################################
# Windows runner template
########################################

setup_windows_template() {
    local vmid=${RUNNER_TEMPLATES[windows]}
    local name="runner-windows-template"

    log "=== Windows Runner Template (VMID ${vmid}) ==="

    if qm config "$vmid" >/dev/null 2>&1; then
        log "Removing existing template ${vmid}..."
        qm stop "$vmid" 2>/dev/null || true
        sleep 2
        qm destroy "$vmid" --purge 1 2>/dev/null || true
    fi

    log "Creating Windows VM..."
    qm create "$vmid" \
        --name "$name" \
        --ostype win11 \
        --cores "$RUNNER_WINDOWS_CORES" \
        --memory "$RUNNER_WINDOWS_MEM" \
        --net0 "virtio,bridge=${BRIDGE}" \
        --scsihw virtio-scsi-single \
        --machine q35 \
        --bios ovmf \
        --cpu host \
        --agent enabled=1 \
        --tpmstate0 "${STORAGE}:1,version=v2.0"

    qm set "$vmid" --scsi0 "${STORAGE}:64,discard=on,ssd=1"
    qm set "$vmid" --ide0 "${RUNNER_WINDOWS_ISO},media=cdrom"
    qm set "$vmid" --ide1 "nas:iso/virtio-win.iso,media=cdrom"
    qm set "$vmid" --boot "order=ide0;scsi0"
    qm set "$vmid" --efidisk0 "${STORAGE}:1"

    # Copy autounattend for automated install
    log ""
    log "┌──────────────────────────────────────────────────────────┐"
    log "│ Windows template created as VM ${vmid}.                  │"
    log "│                                                          │"
    log "│ Option A — Automated (attach floppy with autounattend):  │"
    log "│   1. Create floppy with autounattend_win11.xml           │"
    log "│   2. Boot VM — Windows installs unattended               │"
    log "│   3. After install, copy + run install_windows_runner.ps1│"
    log "│                                                          │"
    log "│ Option B — Manual:                                       │"
    log "│   1. Boot VM from Proxmox console                        │"
    log "│   2. Install Windows, create user '${SSH_USER}'          │"
    log "│   3. Install OpenSSH server, add SSH key                 │"
    log "│   4. Run: install_windows_runner.ps1                     │"
    log "│                                                          │"
    log "│ Then shut down and convert:                              │"
    log "│   qm set ${vmid} --template 1                            │"
    log "└──────────────────────────────────────────────────────────┘"
}

########################################
# Main
########################################

log "=========================================="
log " NoMercy Runner Template Setup"
log "=========================================="

case "$TARGET" in
    linux)   setup_linux_template ;;
    macos)   setup_macos_template ;;
    windows) setup_windows_template ;;
    all)
        setup_linux_template
        setup_macos_template
        setup_windows_template
        ;;
    *) die "Usage: $0 <linux|macos|windows|all>" ;;
esac

log ""
log "Templates ready. Create runners with:"
log "  ${CI_ROOT}/runners/create_runner.sh linux 3"
log "  ${CI_ROOT}/runners/create_runner.sh macos 1"
log "  ${CI_ROOT}/runners/create_runner.sh windows 1"
