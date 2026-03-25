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
[[ -f "$SSH_PUB_KEY" ]] || die "SSH key not found at ${SSH_PUB_KEY}. Run setup/setup_proxmox_host.sh first."
PUB_KEY=$(cat "$SSH_PUB_KEY")

STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
TARGET="${1:-all}"

# Validate required env vars
validate_env() {
    local os=$1
    case "$os" in
        linux)
            [[ -n "$RUNNER_LINUX_IMAGE" ]] || die "RUNNER_LINUX_IMAGE not set in .env"
            [[ -n "$RUNNER_VERSION" ]] || die "RUNNER_VERSION not set in .env"
            ;;
        macos)
            [[ -n "$RUNNER_MACOS_ISO" ]] || die "RUNNER_MACOS_ISO not set in .env"
            ;;
        windows)
            [[ -n "$RUNNER_WINDOWS_ISO" ]] || die "RUNNER_WINDOWS_ISO not set in .env"
            ;;
    esac
}

########################################
# Linux runner template (Ubuntu 24.04)
########################################

setup_linux_template() {
    local vmid=${RUNNER_TEMPLATES[linux]}
    local name="runner-linux-template"

    log "=== Linux Runner Template (VMID ${vmid}) ==="
    validate_env linux

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
        --serial0 socket \
        --vga serial0 \
        --agent enabled=1,fstrim_cloned_disks=1

    # Import disk
    log "Importing disk image (transfer + format conversion — this can take a few minutes on LVM)..."
    qm set "$vmid" --scsi0 "${STORAGE}:0,import-from=${img},discard=on,ssd=1"
    log "Disk imported. Resizing to 50G..."
    qm resize "$vmid" scsi0 50G
    log "Setting boot order..."
    qm set "$vmid" --boot order=scsi0

    # Cloud-init
    log "Configuring cloud-init..."
    qm set "$vmid" --ide2 "${STORAGE}:cloudinit"
    qm set "$vmid" --ciuser "$SSH_USER"
    qm set "$vmid" --sshkeys "$SSH_PUB_KEY"
    qm set "$vmid" --ipconfig0 "ip=dhcp"
    qm set "$vmid" --ciupgrade 1
    log "Cloud-init configured."

    # Start and wait for cloud-init + SSH
    qm start "$vmid"
    log "VM started. Waiting for boot + DHCP..."

    # Get MAC address from VM config
    local mac
    mac=$(qm config "$vmid" | grep '^net0' | grep -oiE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' | head -1)
    [[ -n "$mac" ]] || die "Could not find MAC address for VM ${vmid}"
    local mac_lower
    mac_lower=$(echo "$mac" | tr '[:upper:]' '[:lower:]')
    log "MAC: ${mac}"

    # Wait for cloud-init to bring up networking
    sleep 30

    # Find IP — scan the bridge interface for our MAC
    local ip=""
    log "Scanning for VM on network..."

    # Install arp-scan if not present
    command -v arp-scan >/dev/null 2>&1 || apt-get install -y arp-scan >/dev/null 2>&1

    for attempt in $(seq 1 20); do
        # arp-scan is the most reliable way to find a MAC on a bridge
        if command -v arp-scan >/dev/null 2>&1; then
            ip=$(arp-scan --interface="${BRIDGE}" --localnet 2>/dev/null \
                | grep -i "$mac_lower" | awk '{print $1}' | head -1) || true
        fi

        # Fallback: check ARP table
        if [[ -z "$ip" ]]; then
            ip=$(ip -4 neigh show dev "${BRIDGE}" 2>/dev/null \
                | grep -i "$mac_lower" | awk '{print $1}' | head -1) || true
        fi

        if [[ -n "$ip" ]]; then
            log "VM IP: ${ip} (found after ~$((30 + attempt * 5))s)"
            break
        fi

        if (( attempt % 5 == 0 )); then
            log "Still scanning... (attempt ${attempt}/20)"
        fi

        sleep 5
    done

    [[ -n "$ip" ]] || die "Could not find VM ${vmid} on the network after 130s. Is DHCP running on ${BRIDGE}?"

    log "Waiting for SSH..."
    wait_for_ssh "$ip" 180

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
    validate_env macos

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
    qm set "$vmid" --scsi0 "${STORAGE}:50,discard=on,ssd=1"
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
    validate_env windows

    # Ensure genisoimage is available for building the driver ISO
    apt-get install -y --no-install-recommends genisoimage >/dev/null 2>&1

    VIRTIO_ISO="${VIRTIO_ISO:-nas:iso/virtio-win.iso}"
    ISO_STORAGE="${ISO_STORAGE:-nas}"
    ISO_STORAGE_PATH=$(pvesm path "${ISO_STORAGE}:iso/virtio-win.iso" 2>/dev/null | sed 's|/virtio-win.iso$||') \
        || die "Could not determine ISO storage path for '${ISO_STORAGE}'."

    if qm config "$vmid" >/dev/null 2>&1; then
        log "Removing existing template ${vmid}..."
        qm stop "$vmid" --timeout 30 2>/dev/null || true
        sleep 5
        qm destroy "$vmid" --purge 1 2>/dev/null || true
    fi

    # Build driver ISO with autounattend + postinstall scripts
    log "Building driver ISO with unattended install..."
    local tmpdir
    tmpdir=$(mktemp -d)
    local iso_name="nomercy-runner-drivers.iso"
    local iso_path="${ISO_STORAGE_PATH}/${iso_name}"

    cp "${CI_ROOT}/setup/autounattend_win11.xml" "${tmpdir}/autounattend.xml"
    cp "${CI_ROOT}/runners/install_windows_runner.ps1" "${tmpdir}/setup_windows_postinstall.ps1"
    cp "$SSH_PUB_KEY" "${tmpdir}/ci_ed25519.pub"

    # SetupComplete.cmd — runs after OOBE, installs runner tools
    cat > "${tmpdir}/SetupComplete.cmd" << 'BATCH'
@echo off
echo [%TIME%] SetupComplete.cmd started >> C:\ci-setup.log
if exist "C:\Windows\Setup\Scripts\setup_windows_postinstall.ps1" (
    echo [%TIME%] Found postinstall at C:\Windows\Setup\Scripts >> C:\ci-setup.log
    powershell -ExecutionPolicy Bypass -File "C:\Windows\Setup\Scripts\setup_windows_postinstall.ps1"
    goto :eof
)
for %%d in (D E F G H I) do (
    if exist "%%d:\setup_windows_postinstall.ps1" (
        echo [%TIME%] Found postinstall on %%d: >> C:\ci-setup.log
        powershell -ExecutionPolicy Bypass -File "%%d:\setup_windows_postinstall.ps1"
        goto :eof
    )
)
echo [%TIME%] ERROR: setup_windows_postinstall.ps1 not found >> C:\ci-setup.log
BATCH

    genisoimage -o "$iso_path" -J -r -V "CI_DRIVERS" "$tmpdir" >/dev/null 2>&1
    rm -rf "$tmpdir"
    log "Driver ISO: ${iso_path}"

    # Create VM — same pattern as setup/setup_windows_template.sh
    # Use win10 ostype to avoid BSOD on second boot (known Proxmox issue)
    log "Creating Windows VM..."
    qm create "$vmid" \
        --name "$name" \
        --memory "$RUNNER_WINDOWS_MEM" \
        --cores "$RUNNER_WINDOWS_CORES" \
        --cpu host \
        --machine q35 \
        --bios ovmf \
        --efidisk0 "${STORAGE}:1,efitype=4m" \
        --scsihw virtio-scsi-pci \
        --scsi0 "${STORAGE}:50" \
        --sata0 "${VIRTIO_ISO},media=cdrom" \
        --sata1 "${ISO_STORAGE}:iso/${iso_name},media=cdrom" \
        --sata2 "${RUNNER_WINDOWS_ISO},media=cdrom" \
        --net0 "virtio,bridge=${BRIDGE}" \
        --ostype win10 \
        --agent enabled=1 \
        --boot "order=sata2;scsi0"

    # Start and wait for unattended install + sysprep
    log "Starting VM — unattended install will begin..."
    qm start "$vmid"

    # Send keypresses to get past "Press any key to boot from CD..."
    log "Sending keypresses to boot from CD..."
    for _i in 1 2 3 4 5; do
        sleep 3
        qm sendkey "$vmid" ret 2>/dev/null || true
    done

    log "Waiting for install + sysprep to complete (auto-shutdown)..."
    log "This typically takes 20-40 minutes. Polling every 30s..."

    local timeout=3600
    local elapsed=0
    local interval=30

    while true; do
        local status
        status=$(qm status "$vmid" 2>/dev/null | awk '{print $2}')

        if [[ "$status" == "stopped" ]]; then
            log "VM has shut down (sysprep complete)."
            break
        fi

        elapsed=$((elapsed + interval))
        if (( elapsed >= timeout )); then
            die "Timeout after ${timeout}s. Check Proxmox console for errors."
        fi

        if (( elapsed % 300 == 0 )); then
            log "Still waiting... (${elapsed}s elapsed, status: ${status})"
        fi

        sleep "$interval"
    done

    # Clean up ISOs and convert to template
    log "Removing CD/DVD drives..."
    qm set "$vmid" --delete sata0 2>/dev/null || true
    qm set "$vmid" --delete sata1 2>/dev/null || true
    qm set "$vmid" --delete sata2 2>/dev/null || true

    log "Converting VM ${vmid} to template..."
    qm template "$vmid"
    log "Windows runner template ready (VMID ${vmid})"
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
