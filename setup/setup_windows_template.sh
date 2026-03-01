#!/usr/bin/env bash
# Automated Windows VM template creation for NoMercy CI
# Run as root on the Proxmox VE host after setup_proxmox_host.sh.
#
# Usage:
#   ./setup_windows_template.sh           # Build both Win10 and Win11 templates
#   ./setup_windows_template.sh win10     # Build only Win10
#   ./setup_windows_template.sh win11     # Build only Win11
#
# Prerequisites:
#   - Windows ISOs uploaded to Proxmox (nas storage)
#   - VirtIO drivers ISO uploaded to Proxmox
#   - CI SSH key generated (setup_proxmox_host.sh)

set -Eeuo pipefail

CI_ROOT="/opt/nomercy-ci"
source "${CI_ROOT}/config.sh"

VIRTIO_ISO="${VIRTIO_ISO:-nas:iso/virtio-win.iso}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
ISO_STORAGE="${ISO_STORAGE:-nas}"
SSH_PUB_KEY="${CI_ROOT}/.ssh/ci_ed25519.pub"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { log "FATAL: $*"; exit 1; }

[[ -f "$SSH_PUB_KEY" ]] || die "SSH public key not found at ${SSH_PUB_KEY}. Run setup_proxmox_host.sh first."

# Check prerequisites
apt-get install -y --no-install-recommends genisoimage >/dev/null 2>&1

# Determine ISO storage filesystem path
ISO_STORAGE_PATH=$(pvesm path "${ISO_STORAGE}:iso/virtio-win.iso" 2>/dev/null | sed 's|/virtio-win.iso$||') \
    || die "Could not determine ISO storage path for '${ISO_STORAGE}'. Check storage config."

########################################
# Build a driver ISO for a specific Windows version
########################################

build_driver_iso() {
    local win_ver=$1   # win10 or win11
    local iso_name="nomercy-ci-drivers-${win_ver}.iso"
    local iso_path="${ISO_STORAGE_PATH}/${iso_name}"
    local tmpdir
    tmpdir=$(mktemp -d)

    # Use >&2 for all log output so it doesn't pollute the captured return value
    log "[${win_ver}] Building driver ISO..." >&2

    # Pick the correct autounattend.xml
    if [[ "$win_ver" == "win11" ]]; then
        cp "${CI_ROOT}/setup/autounattend_win11.xml" "${tmpdir}/autounattend.xml"
    else
        cp "${CI_ROOT}/setup/autounattend_win10.xml" "${tmpdir}/autounattend.xml"
    fi

    cp "${CI_ROOT}/setup/setup_windows_postinstall.ps1" "${tmpdir}/setup_windows_postinstall.ps1"
    cp "${SSH_PUB_KEY}" "${tmpdir}/ci_ed25519.pub"

    # SetupComplete.cmd — runs after OOBE as SYSTEM, tries local copy first (placed by specialize pass)
    cat > "${tmpdir}/SetupComplete.cmd" << 'BATCH'
@echo off
echo [%TIME%] SetupComplete.cmd started >> C:\ci-setup.log
REM Try local copy first (placed by specialize pass — most reliable)
if exist "C:\Windows\Setup\Scripts\setup_windows_postinstall.ps1" (
    echo [%TIME%] Found postinstall at C:\Windows\Setup\Scripts >> C:\ci-setup.log
    powershell -ExecutionPolicy Bypass -File "C:\Windows\Setup\Scripts\setup_windows_postinstall.ps1"
    goto :eof
)
REM Fallback: search CD-ROM drives
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

    log "[${win_ver}] Driver ISO: ${iso_path}" >&2
    echo "$iso_name"
}

########################################
# Create, install, and templatize one Windows VM
########################################

setup_windows() {
    local win_ver=$1   # win10 or win11
    local vmid=${WIN_TEMPLATES[$win_ver]}
    local win_iso=${WIN_ISOS[$win_ver]}
    # Use win10 ostype for all versions — win11 ostype causes BSOD during second boot on some Proxmox setups
    local ostype="win10"
    local vm_name="${win_ver}-ci-template"

    log ""
    log "=========================================="
    log " Setting up ${win_ver} template (VMID ${vmid})"
    log "=========================================="

    # Build driver ISO
    local driver_iso_name
    driver_iso_name=$(build_driver_iso "$win_ver")

    # Remove existing VM/template
    if qm config "$vmid" >/dev/null 2>&1; then
        log "[${win_ver}] Removing existing VM/template ${vmid}..."
        qm stop "$vmid" --timeout 30 2>/dev/null || true
        sleep 5
        qm destroy "$vmid" --purge 1 2>/dev/null || true
    fi

    # Create VM
    log "[${win_ver}] Creating VM..."
    local -a qm_args=(
        --name "$vm_name"
        --memory "$WIN_MEM"
        --balloon "$WIN_BALLOON"
        --cores "$WIN_CORES"
        --cpu host
        --machine q35
        --bios ovmf
        --efidisk0 "${STORAGE}:1,efitype=4m"
        --scsihw virtio-scsi-pci
        --scsi0 "${STORAGE}:30"
        --sata0 "${VIRTIO_ISO},media=cdrom"
        --sata1 "${ISO_STORAGE}:iso/${driver_iso_name},media=cdrom"
        --sata2 "${win_iso},media=cdrom"
        --net0 "virtio,bridge=${BRIDGE}"
        --ostype "$ostype"
        --agent enabled=1
        --boot "order=sata2;scsi0"
    )

    # NOTE: No virtual TPM — swtpm can cause BSOD during second boot on some Proxmox setups.
    # The BypassTPMCheck registry key in WinPE handles the Win11 requirement check instead.

    qm create "$vmid" "${qm_args[@]}"
    log "[${win_ver}] VM ${vmid} created."

    # Start and wait for install + sysprep
    log "[${win_ver}] Starting VM — unattended install will begin..."
    qm start "$vmid"

    # OVMF + Windows ISO shows "Press any key to boot from CD or DVD..."
    # Send keypresses to get past this prompt (timing varies by host speed)
    log "[${win_ver}] Sending keypresses to boot from CD..."
    for _i in 1 2 3 4 5; do
        sleep 3
        qm sendkey "$vmid" ret 2>/dev/null || true
    done

    log "[${win_ver}] Waiting for install + sysprep to complete (auto-shutdown)..."
    log "[${win_ver}] This typically takes 20-40 minutes. Polling every 30s..."

    local timeout=3600
    local elapsed=0
    local interval=30

    while true; do
        local status
        status=$(qm status "$vmid" 2>/dev/null | awk '{print $2}')

        if [[ "$status" == "stopped" ]]; then
            log "[${win_ver}] VM has shut down (sysprep complete)."
            break
        fi

        elapsed=$((elapsed + interval))
        if (( elapsed >= timeout )); then
            die "[${win_ver}] Timeout after ${timeout}s. Check Proxmox console for errors."
        fi

        if (( elapsed % 300 == 0 )); then
            log "[${win_ver}] Still waiting... (${elapsed}s elapsed, status: ${status})"
        fi

        sleep "$interval"
    done

    # Clean up ISOs and convert to template
    log "[${win_ver}] Removing CD/DVD drives..."
    qm set "$vmid" --delete sata0 2>/dev/null || true
    qm set "$vmid" --delete sata1 2>/dev/null || true
    qm set "$vmid" --delete sata2 2>/dev/null || true

    log "[${win_ver}] Converting VM ${vmid} to template..."
    qm template "$vmid"

    log "[${win_ver}] Template created! (VMID ${vmid})"
}

########################################
# Main
########################################

VERSIONS=("${@:-win10 win11}")
# If no args, default to both
if [[ $# -eq 0 ]]; then
    VERSIONS=(win10 win11)
fi

for ver in "${VERSIONS[@]}"; do
    case "$ver" in
        win10|win11)
            setup_windows "$ver"
            ;;
        *)
            die "Unknown version: ${ver}. Use 'win10' or 'win11'."
            ;;
    esac
done

log ""
log "=========================================="
log " Windows templates ready:"
for ver in "${VERSIONS[@]}"; do
    log "   ${ver} -> VMID ${WIN_TEMPLATES[$ver]}"
done
log ""
log " Each template includes:"
log "   - OpenSSH Server (key-only auth)"
log "   - CI user with SSH key"
log "   - Firewall rules for SSH (22) and NoMercy (7626)"
log "   - VirtIO drivers + QEMU guest agent"
log "   - Sysprep'd for unique SID on each clone"
log "=========================================="
