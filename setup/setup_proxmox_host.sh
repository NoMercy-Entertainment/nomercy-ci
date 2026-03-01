#!/usr/bin/env bash
# One-time Proxmox host setup for NoMercy CI
# Run as root on the Proxmox VE host.

set -Eeuo pipefail

CI_ROOT="/opt/nomercy-ci"
SSH_KEY="${CI_ROOT}/.ssh/ci_ed25519"
TRUENAS_IP="${TRUENAS_IP:?Set TRUENAS_IP before running, e.g. TRUENAS_IP=192.168.1.100 $0}"
NFS_PATH="${NFS_PATH:-/mnt/pool/nomercy-artifacts}"
MOUNT_POINT="/mnt/vault/nomercy-artifacts"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

########################################
# 1. Fix Proxmox repos (Community Edition)
########################################

# PVE 9 (Trixie) uses DEB822 .sources files, PVE 8 (Bookworm) uses .list files.
# We need to handle both formats.

log "Configuring Proxmox Community Edition repos..."
CODENAME=$(grep VERSION_CODENAME /etc/os-release | cut -d= -f2)

# --- Disable enterprise repos ---

# DEB822 format (.sources) — PVE 9+
# Add "Enabled: false" if not already present
for sources_file in \
    /etc/apt/sources.list.d/pve-enterprise.sources \
    /etc/apt/sources.list.d/ceph.sources; do
    if [[ -f "$sources_file" ]]; then
        if ! grep -qi "^Enabled: false" "$sources_file"; then
            # Append "Enabled: false" after each "Types:" stanza
            sed -i '/^Types:/a Enabled: false' "$sources_file"
            log "Disabled enterprise repo: ${sources_file}"
        else
            log "Already disabled: ${sources_file}"
        fi
    fi
done

# Legacy format (.list) — PVE 8
for list_file in \
    /etc/apt/sources.list.d/pve-enterprise.list \
    /etc/apt/sources.list.d/ceph.list; do
    if [[ -f "$list_file" ]]; then
        sed -i 's/^deb/#deb/' "$list_file"
        log "Disabled enterprise repo: ${list_file}"
    fi
done

# --- Enable free no-subscription repos ---

# PVE repo: only add .list if no .sources file already provides pve-no-subscription
if grep -rq "pve-no-subscription" /etc/apt/sources.list.d/*.sources 2>/dev/null; then
    log "PVE no-subscription repo already configured via .sources file"
    # Clean up any duplicate .list we may have created on a previous run
    rm -f /etc/apt/sources.list.d/pve-no-subscription.list
else
    PVE_FREE_REPO="/etc/apt/sources.list.d/pve-no-subscription.list"
    echo "deb http://download.proxmox.com/debian/pve ${CODENAME} pve-no-subscription" > "$PVE_FREE_REPO"
    log "Added PVE no-subscription repo (${CODENAME})"
fi

# Ceph repo: determine release name, add if not already present
CEPH_RELEASE="ceph-squid"
if [[ "$CODENAME" == "bookworm" ]]; then
    CEPH_RELEASE="ceph-reef"
fi

if grep -rq "no-subscription" /etc/apt/sources.list.d/ceph*.sources 2>/dev/null; then
    log "Ceph no-subscription repo already configured via .sources file"
    rm -f /etc/apt/sources.list.d/ceph-no-subscription.list
elif [[ -f /etc/apt/sources.list.d/ceph-no-subscription.list ]] \
     && grep -q "no-subscription" /etc/apt/sources.list.d/ceph-no-subscription.list 2>/dev/null; then
    log "Ceph no-subscription repo already configured via .list file"
else
    echo "deb http://download.proxmox.com/debian/${CEPH_RELEASE} ${CODENAME} no-subscription" \
        > /etc/apt/sources.list.d/ceph-no-subscription.list
    log "Added Ceph no-subscription repo (${CEPH_RELEASE}/${CODENAME})"
fi

########################################
# 2. Install prerequisites
########################################

log "Installing prerequisites..."
apt-get update -qq
apt-get install -y --no-install-recommends \
    jq \
    curl \
    python3 \
    openssh-client \
    nfs-common \
    rsync

########################################
# 3. Deploy CI scripts
########################################

log "Deploying CI scripts to ${CI_ROOT}..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rsync -a --delete "${SCRIPT_DIR}/" "${CI_ROOT}/"
find "${CI_ROOT}" -name "*.sh" -exec chmod +x {} \;
find "${CI_ROOT}/platforms" -name "*.sh" -exec chmod +x {} \;

########################################
# 4. Generate SSH key for CI user
########################################

mkdir -p "$(dirname "$SSH_KEY")"
chmod 700 "$(dirname "$SSH_KEY")"

if [[ ! -f "$SSH_KEY" ]]; then
    log "Generating SSH keypair at ${SSH_KEY}..."
    ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C "nomercy-ci@$(hostname)"
    log "Public key:"
    cat "${SSH_KEY}.pub"
    log ""
    log "IMPORTANT: Add the public key above to:"
    log "  - All LXC templates (as root and ci user's authorized_keys)"
    log "  - The Windows VM template (C:\\Users\\ci\\.ssh\\authorized_keys)"
else
    log "SSH key already exists at ${SSH_KEY}"
fi

########################################
# 5. NFS mount for TrueNAS artifacts
########################################

mkdir -p "$MOUNT_POINT"

FSTAB_ENTRY="${TRUENAS_IP}:${NFS_PATH} ${MOUNT_POINT} nfs defaults,_netdev,nofail 0 0"

if grep -qF "$MOUNT_POINT" /etc/fstab; then
    log "NFS mount already in /etc/fstab"
else
    log "Adding NFS mount to /etc/fstab..."
    echo "$FSTAB_ENTRY" >> /etc/fstab
fi

if ! mountpoint -q "$MOUNT_POINT"; then
    log "Mounting NFS share..."
    mount "$MOUNT_POINT"
fi
log "NFS mounted: ${MOUNT_POINT}"

########################################
# 6. Install and enable webhook service
########################################

log "Installing nomercy-ci.service..."
cp "${CI_ROOT}/webhook/nomercy-ci.service" /etc/systemd/system/nomercy-ci.service

ENV_FILE="${CI_ROOT}/webhook/webhook_server.env"
if grep -q "CHANGE_ME" "$ENV_FILE"; then
    log ""
    log "WARNING: Edit ${ENV_FILE} and set GITHUB_SECRET before enabling the webhook service."
    log "Then run:"
    log "  systemctl daemon-reload"
    log "  systemctl enable --now nomercy-ci"
else
    systemctl daemon-reload
    systemctl enable --now nomercy-ci
    log "Webhook service enabled and started."
fi

########################################
# Done
########################################

log ""
log "=========================================="
log " Host setup complete."
log " Next steps:"
log "  1. Edit ${ENV_FILE} and set GITHUB_SECRET"
log "  2. Run: systemctl enable --now nomercy-ci"
log "  3. Run: ${CI_ROOT}/setup/setup_templates.sh"
log "  4. Run: ${CI_ROOT}/setup/setup_windows_template.sh"
log "  5. Add webhook in GitHub: http://<this-host-ip>:9000/webhook"
log "=========================================="
