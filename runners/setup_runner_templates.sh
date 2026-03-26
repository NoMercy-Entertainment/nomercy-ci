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
FORCE=0
TARGET="${1:-all}"
[[ "${2:-}" == "--force" || "${1:-}" == "--force" ]] && FORCE=1
[[ "${1:-}" == "--force" ]] && TARGET="${2:-all}"

# Validate required env vars
validate_env() {
    local os=$1
    case "$os" in
        linux)
            [[ -n "$RUNNER_VERSION" ]] || die "RUNNER_VERSION not set in .env"
            ;;
        macos)
            [[ -n "$RUNNER_OPENCORE_ISO" ]] || die "RUNNER_OPENCORE_ISO not set in .env"
            ;;
        windows)
            [[ -n "$RUNNER_WINDOWS_ISO" ]] || die "RUNNER_WINDOWS_ISO not set in .env"
            ;;
    esac
}

########################################
# Linux runner template (Ubuntu 24.04 LXC)
########################################

setup_linux_template() {
    local ctid=${RUNNER_TEMPLATES[linux]}
    local name="runner-linux-template"
    local tmpl="ubuntu-24.04-standard_24.04-2_amd64.tar.zst"

    log "=== Linux Runner Template (CTID ${ctid}) ==="
    validate_env linux

    # Skip if template already exists
    if pct config "$ctid" >/dev/null 2>&1 && (( FORCE == 0 )); then
        if pct config "$ctid" 2>/dev/null | grep -qi 'template'; then
            log "Linux template already exists (CTID ${ctid}). Skipping. Use --force to recreate."
            return
        fi
    fi

    # Download template if needed
    if ! pveam list local 2>/dev/null | grep -q "$tmpl"; then
        log "Downloading Ubuntu 24.04 LXC template..."
        pveam download local "$tmpl" || die "Failed to download template. Run 'pveam update' first."
    else
        log "Template already downloaded: ${tmpl}"
    fi

    # Remove existing
    if pct config "$ctid" >/dev/null 2>&1; then
        log "Removing existing template ${ctid}..."
        pct stop "$ctid" 2>/dev/null || true
        sleep 2
        pct destroy "$ctid" --purge 2>/dev/null || true
    fi

    # Create container with nesting + Docker support
    log "Creating LXC container..."
    pct create "$ctid" "local:vztmpl/${tmpl}" \
        --hostname "$name" \
        --cores "$RUNNER_LINUX_CORES" \
        --memory "$RUNNER_LINUX_MEM" \
        --swap 1024 \
        --rootfs "${STORAGE}:50" \
        --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
        --unprivileged 1 \
        --features "nesting=1,keyctl=1" \
        --start 1

    log "Waiting for container to boot..."
    sleep 8

    # Get IP
    local ip=""
    for attempt in $(seq 1 20); do
        ip=$(pct exec "$ctid" -- hostname -I 2>/dev/null | awk '{print $1}') || true
        if [[ -n "$ip" && "$ip" != *":"* ]]; then
            log "Container IP: ${ip}"
            break
        fi
        ip=""
        sleep 3
    done
    [[ -n "$ip" ]] || die "Could not get IP for container ${ctid}"

    # Set up CI user + SSH
    log "Configuring CI user and SSH..."
    pct exec "$ctid" -- bash -c "
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y --no-install-recommends openssh-server sudo
        systemctl enable ssh
        systemctl start ssh

        id ${SSH_USER} >/dev/null 2>&1 || useradd -m -s /bin/bash ${SSH_USER}
        echo '${SSH_USER} ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/${SSH_USER}
        chmod 440 /etc/sudoers.d/${SSH_USER}
        mkdir -p /home/${SSH_USER}/.ssh
        echo '${PUB_KEY}' > /home/${SSH_USER}/.ssh/authorized_keys
        chown -R ${SSH_USER}:${SSH_USER} /home/${SSH_USER}/.ssh
        chmod 700 /home/${SSH_USER}/.ssh
        chmod 600 /home/${SSH_USER}/.ssh/authorized_keys
    "

    wait_for_ssh "$ip" 60

    # Install all CI tools
    log "Installing CI tools (this takes 10-20 minutes)..."
    # shellcheck disable=SC2086
    scp $SSH_OPTS "${CI_ROOT}/runners/install_linux_runner.sh" "${SSH_USER}@${ip}:/tmp/install.sh"
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "${SSH_USER}@${ip}" "chmod +x /tmp/install.sh && sudo /tmp/install.sh '${RUNNER_VERSION}'" \
        2>&1 | tee "${RUN_DIR}/linux-install.log"

    # Stop and convert to template
    log "Converting to template..."
    pct stop "$ctid"
    sleep 3
    pct set "$ctid" --template 1
    log "Linux runner template ready (CTID ${ctid})"
}

########################################
# macOS runner template
########################################

setup_macos_template() {
    local vmid=${RUNNER_TEMPLATES[macos]}
    local name="runner-macos-template"
    local osk='ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc'

    log "=== macOS Runner Template (VMID ${vmid}) ==="
    validate_env macos

    # Skip if template already exists
    if qm config "$vmid" >/dev/null 2>&1 && (( FORCE == 0 )); then
        if qm config "$vmid" 2>/dev/null | grep -qi 'template'; then
            log "macOS template already exists (VMID ${vmid}). Skipping. Use --force to recreate."
            return
        fi
    fi

    [[ -n "$RUNNER_OPENCORE_ISO" ]] || die "RUNNER_OPENCORE_ISO not set in .env"

    # Determine ISO storage path
    ISO_STORAGE="${ISO_STORAGE:-nas}"
    local iso_dir
    iso_dir=$(pvesm path "${ISO_STORAGE}:iso/." 2>/dev/null | sed 's|/\.$||') \
        || iso_dir="/mnt/pve/nas/template/iso"

    if qm config "$vmid" >/dev/null 2>&1; then
        log "Removing existing template ${vmid}..."
        qm stop "$vmid" 2>/dev/null || true
        sleep 2
        qm destroy "$vmid" --purge 1 2>/dev/null || true
    fi

    # Download OpenCore ISO if not present
    local opencore_path="${iso_dir}/OpenCore-v21.iso"
    if [[ ! -f "$opencore_path" ]]; then
        log "Downloading OpenCore ISO..."
        curl -fSL "https://github.com/thenickdude/KVM-Opencore/releases/download/v21/OpenCore-v21.iso.gz" \
            -o "${opencore_path}.gz"
        gunzip -f "${opencore_path}.gz"
        log "OpenCore ISO downloaded."
    fi

    # Download macOS BaseSystem from Apple if no installer present
    local macos_raw="${iso_dir}/macOS-BaseSystem.raw"
    if [[ ! -f "$macos_raw" ]]; then
        log "Downloading macOS recovery image from Apple CDN..."
        local tmpdir
        tmpdir=$(mktemp -d)

        # Install python3 if needed
        command -v python3 >/dev/null 2>&1 || apt-get install -y python3

        # Fetch the download script
        curl -fsSL https://raw.githubusercontent.com/kholia/OSX-KVM/master/fetch-macOS-v2.py \
            -o "${tmpdir}/fetch.py"

        # Download macOS Sonoma non-interactively
        local macos_version="${RUNNER_MACOS_VERSION:-sonoma}"
        log "Fetching macOS ${macos_version} from Apple (this may take a few minutes)..."
        cd "${tmpdir}"
        python3 fetch.py --shortname "${macos_version}" 2>&1 | tail -10 || \
            python3 fetch.py -s "${macos_version}" 2>&1 | tail -10
        cd - >/dev/null

        # Find the downloaded BaseSystem.dmg
        local dmg
        dmg=$(find "${tmpdir}" -maxdepth 2 -name "BaseSystem.dmg" -o -name "RecoveryImage.dmg" 2>/dev/null | head -1)

        if [[ -z "$dmg" ]]; then
            rm -rf "$tmpdir"
            die "Failed to download macOS BaseSystem.dmg"
        fi

        log "Converting DMG to raw disk image..."
        qemu-img convert -f dmg -O raw "$dmg" "$macos_raw"
        rm -rf "$tmpdir"
        log "macOS recovery image ready."
    fi

    log "Creating macOS VM with OpenCore bootloader..."
    qm create "$vmid" \
        --name "$name" \
        --ostype other \
        --cores "$RUNNER_MACOS_CORES" \
        --memory "$RUNNER_MACOS_MEM" \
        --net0 "vmxnet3,bridge=${BRIDGE}" \
        --bios ovmf \
        --machine q35 \
        --cpu host \
        --agent enabled=1

    # Disks
    log "Creating disks..."
    qm set "$vmid" --sata2 "${STORAGE}:50,discard=on,ssd=1"
    qm set "$vmid" --efidisk0 "${STORAGE}:1"

    # Import OpenCore as a disk (GPT disk image, not a bootable CD)
    log "Importing OpenCore disk..."
    qm importdisk "$vmid" "$opencore_path" "${STORAGE}" >/dev/null
    local oc_disk
    oc_disk=$(qm config "$vmid" | grep '^unused' | tail -1 | awk '{print $2}')
    qm set "$vmid" --sata1 "$oc_disk"

    # Import macOS BaseSystem as a disk (OpenCore reads disks, not CD-ROMs)
    log "Importing macOS recovery disk..."
    qm importdisk "$vmid" "$macos_raw" "${STORAGE}" >/dev/null
    local mac_disk
    mac_disk=$(qm config "$vmid" | grep '^unused' | tail -1 | awk '{print $2}')
    qm set "$vmid" --sata0 "$mac_disk"

    # Boot from OpenCore (sata1) first, then main disk (sata2)
    qm set "$vmid" --boot "order=sata1;sata2"

    # Add Apple SMC key + CPU flags directly to config
    # (qm set mangles the args string, so write directly)
    log "Configuring Apple SMC passthrough and CPU flags..."
    sed -i '/^args:/d' "/etc/pve/qemu-server/${vmid}.conf"
    cat >> "/etc/pve/qemu-server/${vmid}.conf" << ARGSEOF
args: -device isa-applesmc,osk="${osk}" -smbios type=2 -device usb-kbd,bus=ehci.0,port=2 -global nec-usb-xhci.msi=off -global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off -cpu host,kvm=on,vendor=GenuineIntel,+kvm_pv_unhalt,+kvm_pv_eoi,+hypervisor,+invtsc
ARGSEOF

    log "Starting VM..."
    qm start "$vmid"

    log ""
    log "============================================================"
    log " macOS VM ${vmid} is booting with OpenCore."
    log ""
    log " Complete these steps in the Proxmox console:"
    log ""
    log " 1. OpenCore boot picker — select the macOS installer"
    log " 2. Disk Utility — erase the ~50 GB SATA disk as APFS"
    log " 3. Install macOS to that disk"
    log " 4. On reboot — select 'macOS Installer' in OpenCore"
    log " 5. After final reboot — select 'Macintosh HD'"
    log " 6. Create user '${SSH_USER}' during setup"
    log " 7. System Settings > General > Sharing > enable Remote Login"
    log " 8. Open Terminal and run:"
    log "    mkdir -p ~/.ssh && echo '${PUB_KEY}' >> ~/.ssh/authorized_keys"
    log ""
    log " Waiting for SSH to become available..."
    log "============================================================"

    # Wait for the user to complete macOS install + enable SSH
    local ip=""
    local attempt=0
    while true; do
        attempt=$((attempt + 1))

        # Try to find IP via ARP scan on the bridge
        local mac
        mac=$(qm config "$vmid" | grep '^net0' | grep -oiE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' | head -1)
        if [[ -n "$mac" ]]; then
            if command -v arp-scan >/dev/null 2>&1; then
                ip=$(arp-scan --interface="${BRIDGE}" --localnet 2>/dev/null \
                    | grep -i "$(echo "$mac" | tr '[:upper:]' '[:lower:]')" \
                    | awk '{print $1}' | head -1) || true
            fi
            if [[ -z "$ip" ]]; then
                ip=$(ip -4 neigh show dev "${BRIDGE}" 2>/dev/null \
                    | grep -i "$(echo "$mac" | tr '[:upper:]' '[:lower:]')" \
                    | awk '{print $1}' | head -1) || true
            fi
        fi

        # Try SSH if we have an IP
        if [[ -n "$ip" ]]; then
            # shellcheck disable=SC2086
            if ssh $SSH_OPTS "${SSH_USER}@${ip}" "echo ready" >/dev/null 2>&1; then
                log "SSH connected at ${ip}!"
                break
            fi
        fi

        if (( attempt % 12 == 0 )); then
            log "Still waiting for macOS install + SSH... ($(( attempt / 2 )) min elapsed)"
        fi

        sleep 10
    done

    # Install CI tools
    log "Installing CI tools via SSH..."
    # shellcheck disable=SC2086
    scp $SSH_OPTS "${CI_ROOT}/runners/install_macos_runner.sh" "${SSH_USER}@${ip}:/tmp/install.sh"
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "${SSH_USER}@${ip}" "chmod +x /tmp/install.sh && /tmp/install.sh '${RUNNER_VERSION}'" \
        2>&1 | tee "${RUN_DIR}/macos-install.log"

    # Stop and convert to template
    log "Shutting down and converting to template..."
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "${SSH_USER}@${ip}" "sudo shutdown -h now" 2>/dev/null || true
    sleep 10

    # Wait for VM to stop
    for i in $(seq 1 30); do
        status=$(qm status "$vmid" 2>/dev/null | awk '{print $2}')
        [[ "$status" == "stopped" ]] && break
        sleep 5
    done
    qm stop "$vmid" 2>/dev/null || true

    qm set "$vmid" --template 1
    log "macOS runner template ready (VMID ${vmid})"
}

########################################
# Windows runner template
########################################

setup_windows_template() {
    local vmid=${RUNNER_TEMPLATES[windows]}
    local name="runner-windows-template"

    log "=== Windows Runner Template (VMID ${vmid}) ==="
    validate_env windows

    # Skip if template already exists
    if qm config "$vmid" >/dev/null 2>&1 && (( FORCE == 0 )); then
        if qm config "$vmid" 2>/dev/null | grep -qi 'template'; then
            log "Windows template already exists (VMID ${vmid}). Skipping. Use --force to recreate."
            return
        fi
    fi

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

    cp "${CI_ROOT}/setup/autounattend_win10.xml" "${tmpdir}/autounattend.xml"
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
