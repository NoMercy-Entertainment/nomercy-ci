#!/usr/bin/env bash
# Create/refresh LXC base templates for NoMercy CI
# Run as root on the Proxmox VE host after setup_proxmox_host.sh.
#
# This script:
#   1. Downloads official Proxmox LXC templates
#   2. Creates a container from each
#   3. Installs common CI dependencies + CI user + SSH key
#   4. Converts each container to a template
#
# Template CTIDs: ubuntu=2000, debian=2001, fedora=2002, arch=2003
# (configured in config.sh)

set -Eeuo pipefail

CI_ROOT="/opt/nomercy-ci"
source "${CI_ROOT}/config.sh"

SSH_PUB_KEY="${CI_ROOT}/.ssh/ci_ed25519.pub"
STORAGE="${STORAGE:-local-lvm}"   # Proxmox storage for containers
BRIDGE="${BRIDGE:-vmbr0}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { log "FATAL: $*"; exit 1; }

[[ -f "$SSH_PUB_KEY" ]] || die "SSH public key not found at ${SSH_PUB_KEY}. Run setup_proxmox_host.sh first."
PUB_KEY=$(cat "$SSH_PUB_KEY")

########################################
# Template definitions
# Format: "CTID:proxmox-template-name:distro-id"
########################################

declare -A TEMPLATE_MAP=(
    [ubuntu]="ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
    [debian]="debian-13-standard_13.1-2_amd64.tar.zst"
    [fedora]="fedora-43-default_20260115_amd64.tar.xz"
)

# Arch Linux is not available from Proxmox repos — download from linuxcontainers.org
ARCH_ROOTFS_URL="https://images.linuxcontainers.org/images/archlinux/current/amd64/default"
ARCH_TEMPLATE_NAME="archlinux-current_amd64.tar.xz"

########################################
# Download templates
########################################

log "Downloading LXC templates..."

# Official Proxmox templates
for tmpl in "${TEMPLATE_MAP[@]}"; do
    if pveam list local 2>/dev/null | grep -q "$tmpl"; then
        log "Template already downloaded: ${tmpl}"
    else
        log "Downloading ${tmpl}..."
        pveam download local "$tmpl" || log "WARNING: Could not download ${tmpl} — run 'pveam update' first"
    fi
done

# Arch Linux from linuxcontainers.org
ARCH_CACHE="/var/lib/vz/template/cache/${ARCH_TEMPLATE_NAME}"
if [[ -f "$ARCH_CACHE" ]]; then
    log "Arch template already downloaded: ${ARCH_TEMPLATE_NAME}"
else
    log "Downloading Arch Linux rootfs from linuxcontainers.org..."
    # Get the latest build directory
    ARCH_INDEX=$(curl -sf "${ARCH_ROOTFS_URL}/") || die "Failed to fetch Arch build index"
    ARCH_BUILD=$(echo "$ARCH_INDEX" | grep -oP '\d{8}_\d{2}:\d{2}' | sort | tail -1)
    if [[ -z "$ARCH_BUILD" ]]; then
        die "Could not find latest Arch Linux build"
    fi
    log "Latest Arch build: ${ARCH_BUILD}"
    curl -fL "${ARCH_ROOTFS_URL}/${ARCH_BUILD}/rootfs.tar.xz" -o "$ARCH_CACHE" \
        || die "Failed to download Arch rootfs"
    log "Arch template downloaded to ${ARCH_CACHE}"
fi

########################################
# Helper: build one base template container
########################################

setup_container() {
    local name=$1
    local ctid=${LXC_TEMPLATES[$name]}
    local tmpl
    if [[ "$name" == "arch" ]]; then
        tmpl="$ARCH_TEMPLATE_NAME"
    else
        tmpl="${TEMPLATE_MAP[$name]}"
    fi

    log "=== Setting up ${name} (CTID ${ctid}) ==="

    # Remove existing template if rebuilding
    if pct config "$ctid" >/dev/null 2>&1; then
        log "Removing existing container/template ${ctid}..."
        pct stop "$ctid" 2>/dev/null || true
        pct destroy "$ctid" --purge 2>/dev/null || true
    fi

    # Create container
    log "Creating container from ${tmpl}..."
    pct create "$ctid" "local:vztmpl/${tmpl}" \
        --hostname "ci-${name}-base" \
        --cores 2 \
        --memory 2048 \
        --swap 512 \
        --rootfs "${STORAGE}:10" \
        --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
        --unprivileged 1 \
        --features "nesting=1" \
        --start 1

    log "Waiting for container to boot..."
    sleep 8

    # Install common dependencies (distro-specific)
    case "$name" in
        ubuntu|debian)
            pct exec "$ctid" -- bash -c "
                export DEBIAN_FRONTEND=noninteractive
                apt-get update -qq
                apt-get install -y --no-install-recommends \
                    curl ca-certificates openssh-server sudo net-tools
                systemctl enable ssh
            "
            ;;
        fedora)
            pct exec "$ctid" -- bash -c "
                dnf install -y curl ca-certificates openssh-server sudo net-tools
                systemctl enable sshd
            "
            ;;
        arch)
            pct exec "$ctid" -- bash -c "
                # Disable Landlock sandboxing — not supported in unprivileged LXC
                sed -i 's/^#*DisableSandbox.*/DisableSandbox/' /etc/pacman.conf
                if ! grep -q '^DisableSandbox' /etc/pacman.conf; then
                    sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf
                fi
                pacman -Syu --noconfirm
                pacman -S --noconfirm curl openssh sudo net-tools
                systemctl enable sshd
            "
            ;;
    esac

    # Create CI user and install SSH key
    pct exec "$ctid" -- bash -c "
        id ci >/dev/null 2>&1 || useradd -m -s /bin/bash ci
        echo 'ci ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ci
        chmod 440 /etc/sudoers.d/ci
        mkdir -p /home/ci/.ssh
        echo '${PUB_KEY}' > /home/ci/.ssh/authorized_keys
        chown -R ci:ci /home/ci/.ssh
        chmod 700 /home/ci/.ssh
        chmod 600 /home/ci/.ssh/authorized_keys
    "

    # Disable root SSH login, disable password auth
    pct exec "$ctid" -- bash -c "
        sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
        sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    "

    # Stop and convert to template
    log "Converting ${name} (${ctid}) to template..."
    pct stop "$ctid"
    sleep 3
    pct set "$ctid" --template 1
    log "${name} template created (CTID ${ctid})"
}

########################################
# Build all templates
########################################

log "Building LXC base templates..."
for distro in ubuntu debian fedora arch; do
    setup_container "$distro"
done

log ""
log "=========================================="
log " LXC templates ready:"
for distro in ubuntu debian fedora arch; do
    log "   ${distro} -> CTID ${LXC_TEMPLATES[$distro]}"
done
log ""
log " Next: create the Windows VM template."
log " Run: ${CI_ROOT}/setup/setup_windows_template.sh"
log "=========================================="
